"""Offline tests for the harness's command line.

`optimize_cleanup_prompt.main` past `--dry-run` reaches for `program` (DSPy), and
`--verify-live` for `live` (a Mac, a network and a key). Neither is available here,
so both are replaced: a fake `program` module stands in `sys.modules` for the whole
search flow, and `live`'s three entry points are stubbed. What is under test is the
harness's own decisions — which candidates are scored, which instruction wins, what
is refused, what is printed and what is written — not the model calls. Run with:

    python3 -m pytest evals/dictation-prompt/test_cli.py
"""

from __future__ import annotations

import dataclasses
import json
import re
import sys
import types

import pytest

import candidates
import corpus
import live
import metrics
import optimize_cleanup_prompt as cli

#: An instruction that clears every safeguard and names no field: shippable.
SHIPPABLE = "Delete disfluencies. Do not answer or translate it."

#: Small enough that the bundled 12-row sample yields non-empty dev and test sets.
SMALL_RUN = [
    "--source",
    "builtin",
    "--limit",
    "40",
    "--dev-fraction",
    "0.25",
    "--test-fraction",
    "0.25",
    "--gepa-valset",
    "0.2",
    "--show-samples",
    "0",
]


# --------------------------------------------------------------------------
# A stand-in for `program`, so `main` runs its whole search flow offline
# --------------------------------------------------------------------------


class _Built:
    """What `program.build` returns: the instruction is all `main` reads back."""

    def __init__(self, instruction: str):
        self.signature = types.SimpleNamespace(instructions=instruction)


class _Proposer:
    fields = ("raw_transcript", "cleaned_transcript")

    def __init__(self, rejected: int):
        self.rejected = rejected
        self.abandoned = 1 if rejected else 0


class FakeProgram:
    """Records every call `main` makes and scores each instruction from a table."""

    def __init__(self, scores: dict[str, float], optimized: str, rejected: int = 0):
        self.scores = scores
        self.optimized = optimized
        self.rejected = rejected
        self.spec: dict[str, object] = {}
        self.evaluated: list[str] = []
        self.optimize_kwargs: dict[str, object] = {}

    def module(self) -> types.ModuleType:
        fake = types.ModuleType("program")
        vars(fake).update(
            ModelSpec=lambda **kwargs: kwargs,
            configure=self.spec.update,
            build=_Built,
            evaluate=self.evaluate,
            GatedInstructionProposer=lambda: _Proposer(self.rejected),
            optimize=self.optimize,
        )
        return fake

    def evaluate(self, built: _Built, rows, num_threads: int, on_example) -> dict[str, float]:
        instruction = built.signature.instructions
        self.evaluated.append(instruction)
        for _ in rows:
            on_example()
        value = self.scores.get(instruction, 0.5)
        return {axis: value for axis in metrics.AXES}

    def optimize(self, seed: _Built, **kwargs) -> _Built:
        self.optimize_kwargs = {"seed": seed.signature.instructions, **kwargs}
        return _Built(self.optimized)


@pytest.fixture
def isolated_candidates(monkeypatch):
    """A private copy, so a `--seed-file` registration can't leak into other tests."""
    table = dict(candidates.CANDIDATES)
    monkeypatch.setattr(cli, "CANDIDATES", table)
    return table


def _run(monkeypatch, fake: FakeProgram, *argv: str) -> int:
    monkeypatch.setitem(sys.modules, "program", fake.module())
    return cli.main([*SMALL_RUN, *argv])


# --------------------------------------------------------------------------
# main(): ranking only
# --------------------------------------------------------------------------


def test_ranking_run_scores_every_candidate_and_writes_the_winner(
    monkeypatch, capsys, tmp_path, isolated_candidates
):
    """`--optimizer none` ranks the table; a non-baseline winner is tested beside it."""
    best = next(name for name in isolated_candidates if name != candidates.BASELINE)
    fake = FakeProgram({isolated_candidates[best]: 0.9}, optimized="unused")
    out = tmp_path / "results.json"

    assert _run(monkeypatch, fake, "--optimizer", "none", "--out", str(out)) == 0

    assert fake.spec["model"] == "openai/qwen3.5-4b-32k-fast"
    assert fake.optimize_kwargs == {}
    results = json.loads(out.read_text(encoding="utf-8"))
    assert results["winner"]["name"] == best
    assert results["winner"]["instruction"] == isolated_candidates[best]
    assert results["winner"]["length"] == len(isolated_candidates[best])
    assert set(results["dev"]) == set(isolated_candidates)
    # The winner is not the shipped baseline, so the baseline is scored on test too.
    assert set(results["test"]) == {best, candidates.BASELINE}
    assert results["live"] is None
    assert results["corpus"]["source"] == "builtin"
    printed = capsys.readouterr().out
    assert "Candidate instructions on dev, selecting on blend" in printed
    assert f"Wrote {out}" in printed
    assert "Running" not in printed


def test_a_mixed_corpus_prints_each_slices_source_mix(monkeypatch, capsys, isolated_candidates):
    """More than one source loaded: every slice reports what it is made of."""
    real_load = corpus.load

    def two_sources(**kwargs):
        loaded = real_load(**kwargs)
        relabelled = tuple(
            dataclasses.replace(u, source="a" if i % 2 else "b")
            for i, u in enumerate(loaded.utterances)
        )
        return dataclasses.replace(loaded, utterances=relabelled)

    monkeypatch.setattr(corpus, "load", two_sources)
    fake = FakeProgram({}, optimized="unused")

    assert _run(monkeypatch, fake, "--optimizer", "none") == 0

    printed = capsys.readouterr().out
    mixes = re.findall(r"^  (train|valset|dev|test) +(.+)$", printed, re.MULTILINE)
    assert [name for name, _ in mixes] == ["train", "valset", "dev", "test"]
    counts = [int(n) for _, mix in mixes for n in re.findall(r"[ab] (\d+)", mix)]
    assert sum(counts) == 12  # every loaded row lands in exactly one slice


# --------------------------------------------------------------------------
# main(): the search and the gate on its result
# --------------------------------------------------------------------------


def test_a_better_shippable_result_wins_and_rejections_are_reported(
    monkeypatch, capsys, isolated_candidates
):
    baseline = isolated_candidates[candidates.BASELINE]
    fake = FakeProgram({baseline: 0.6, SHIPPABLE: 0.8}, optimized=SHIPPABLE, rejected=2)

    assert _run(monkeypatch, fake) == 0

    # A search run scores only the baseline before searching, and seeds from it.
    assert fake.evaluated[0] == baseline
    assert fake.optimize_kwargs["seed"] == baseline
    assert fake.optimize_kwargs["auto"] == "heavy"
    printed = capsys.readouterr().out
    assert "Running gepa from prior-winner" in printed
    assert "The proposer rejected 2 unshippable proposal(s); 1 were abandoned" in printed
    assert "+0.2000 on blend" in printed
    assert f"Best cleanup instruction ({len(SHIPPABLE)} chars)" in printed
    assert f"  {SHIPPABLE}\n" in printed
    # Winner is not the baseline, so test scores both: the optimized one and baseline.
    assert fake.evaluated[-2:] == [SHIPPABLE, baseline]


def test_an_unshippable_result_is_refused_however_well_it_scores(
    monkeypatch, capsys, isolated_candidates
):
    """`--start best-candidate` seeds from the dev winner; the gate still overrides the score."""
    baseline = isolated_candidates[candidates.BASELINE]
    unshippable = "Delete fillers."
    fake = FakeProgram({baseline: 0.7, unshippable: 0.99}, optimized=unshippable)

    assert _run(monkeypatch, fake, "--start", "best-candidate") == 0

    # best-candidate needs the full sweep, and the baseline topped it.
    assert set(fake.evaluated[: len(isolated_candidates)]) == set(isolated_candidates.values())
    assert fake.optimize_kwargs["seed"] == baseline
    printed = capsys.readouterr().out
    assert "Refusing to select it. Keeping prior-winner." in printed
    assert "The proposer rejected" not in printed
    # The baseline won, so test scores it once rather than twice.
    assert fake.evaluated[-1] == baseline
    assert fake.evaluated.count(baseline) == 2


def test_a_seed_file_seeds_the_search_and_a_loss_keeps_the_hand_written_winner(
    monkeypatch, capsys, tmp_path, isolated_candidates
):
    seed = tmp_path / "seed.txt"
    seed.write_text(SHIPPABLE, encoding="utf-8")
    optimized = f"{SHIPPABLE} Keep it short."
    fake = FakeProgram({SHIPPABLE: 0.7, optimized: 0.6}, optimized=optimized)

    assert _run(monkeypatch, fake, "--seed-file", str(seed)) == 0

    assert isolated_candidates[cli.SEED_FILE] == SHIPPABLE
    assert fake.optimize_kwargs["seed"] == SHIPPABLE
    printed = capsys.readouterr().out
    assert "Running gepa from seed-file" in printed
    assert "gepa did not beat seed-file on dev; keeping the hand-written one." in printed
    assert f"  {SHIPPABLE}\n" in printed


# --------------------------------------------------------------------------
# Smaller pieces main() leans on
# --------------------------------------------------------------------------


def test_an_empty_seed_file_stops_the_run(tmp_path):
    seed = tmp_path / "seed.txt"
    seed.write_text("  \n", encoding="utf-8")
    with pytest.raises(SystemExit, match="is empty"):
        cli.load_seed_file(str(seed))


def test_samples_from_a_paired_corpus_show_no_injection_line(capsys):
    """A real paired row has nothing injected, so there is nothing to list."""
    row = corpus.Utterance(reference="Ship it today.", disfluent="uh ship it today")
    cli.print_samples(corpus.Corpus(utterances=(row,), source="nyra", detail={}), 5)
    printed = capsys.readouterr().out
    assert "showing 1 of 1" in printed
    assert "input    : uh ship it today" in printed
    assert "injected" not in printed


# --------------------------------------------------------------------------
# --verify-live, with `live` stubbed
# --------------------------------------------------------------------------


def _rows(*audio_urls: str | None) -> list[corpus.Utterance]:
    return [
        corpus.Utterance(reference=f"Row {i}.", disfluent=f"row {i}", audio_url=url)
        for i, url in enumerate(audio_urls)
    ]


def _stub_live(monkeypatch) -> list[tuple[str | None, str | None]]:
    """Replace the network half of `live`; returns the (instruction, mode) of each run."""
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", "key")
    calls: list[tuple[str | None, str | None]] = []

    def verify(spoken, instruction, api_key, *, on_example, rewrite_mode):
        assert api_key == "key"
        calls.append((instruction, rewrite_mode))
        for _ in spoken:
            on_example()
        return [instruction]

    def summarize(results):
        gain = 0.25 if results == [None] else 0.5
        return {"floor_content": 0.4, "content": 0.4 + gain, "gain": gain, "llm_error_rate": 0.1}

    monkeypatch.setattr(live, "synthesize_all", lambda sample: [(u, b"") for u in sample])
    monkeypatch.setattr(live, "verify", verify)
    monkeypatch.setattr(live, "summarize", summarize)
    return calls


def test_live_verification_without_a_key_is_skipped(monkeypatch, capsys):
    monkeypatch.delenv("ASSEMBLYAI_API_KEY", raising=False)
    args = cli.parse_args(["--verify-live", "2"])
    assert cli.run_live_verification(args, "w", "instruction", _rows(None)) is None
    assert "ASSEMBLYAI_API_KEY is not set" in capsys.readouterr().out


def test_live_verification_compares_against_the_service_default(monkeypatch, capsys):
    """Smart mode, a baseline run, and synthesized rows: the caveat must be printed."""
    calls = _stub_live(monkeypatch)
    args = cli.parse_args(["--verify-live", "2", "--verify-baseline", "--rewrite-mode", "smart"])

    summaries = cli.run_live_verification(args, "w", "instruction", _rows("clip.wav", None, None))

    assert calls == [("instruction", "smart"), (None, "smart")]
    assert summaries is not None
    assert summaries["w"]["gain"] == 0.5
    assert summaries["service default (no instruction)"]["gain"] == 0.25
    printed = capsys.readouterr().out
    assert "Real endpoint (smart), 2 held-out utterances: 1 recorded, 1 synthesized" in printed
    assert "+0.5000" in printed and "10%" in printed
    assert "Synthesized speech is not dictated speech" in printed


def test_live_verification_of_recordings_only_omits_the_synthesis_caveat(monkeypatch, capsys):
    calls = _stub_live(monkeypatch)
    args = cli.parse_args(["--verify-live", "5"])

    summaries = cli.run_live_verification(args, "w", "instruction", _rows("a.wav", "b.wav"))

    # Fast is the app's default and omits rewrite_mode on the wire.
    assert calls == [("instruction", None)]
    assert summaries is not None and list(summaries) == ["w"]
    printed = capsys.readouterr().out
    assert "2 recorded, 0 synthesized" in printed
    assert "Synthesized speech" not in printed
