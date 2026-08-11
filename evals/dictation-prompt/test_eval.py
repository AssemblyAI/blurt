"""Offline tests for the corpus and scoring halves of the eval.

These need no network and no API key: they pin the properties the results depend
on — that injection is deterministic and additive, that the metric bottoms out and
tops out where it should, that de-tagging turns annotation conventions into
transcript text, and that the splits are disjoint. Run with:

    python3 -m pytest evals/dictation-prompt/test_eval.py
"""

from __future__ import annotations

import importlib.util
import io
import pathlib
import re
import sys

import pytest

import candidates
import corpus
import metrics
import optimize_cleanup_prompt as cli
import progress
from disfluency import inject

SENTENCE = (
    "The build failed because the signing certificate expired over the weekend "
    "and nobody noticed until Monday morning."
)


def disfluent(reference: str, **kwargs) -> str:
    return inject(reference, **kwargs)[0]


# --------------------------------------------------------------------------
# Disfluency injection
# --------------------------------------------------------------------------


def test_injection_is_deterministic_for_a_seed():
    assert inject(SENTENCE, seed=11, severity=0.5) == inject(SENTENCE, seed=11, severity=0.5)


def test_different_seeds_produce_different_utterances():
    assert len({disfluent(SENTENCE, seed=seed, severity=0.5) for seed in range(12)}) > 1


def test_severity_zero_leaves_the_reference_alone():
    assert inject(SENTENCE, seed=3, severity=0.0) == (SENTENCE, ())


def test_severity_out_of_range_is_rejected():
    with pytest.raises(ValueError):
        inject(SENTENCE, seed=3, severity=1.5)


def test_higher_severity_injects_more():
    light = len(disfluent(SENTENCE, seed=5, severity=0.15).split())
    heavy = len(disfluent(SENTENCE, seed=5, severity=0.9).split())
    assert heavy > light


def test_injection_only_adds_tokens():
    """Every reference word must survive, in order — the eval's ceiling depends on it."""
    for seed in range(40):
        produced = disfluent(SENTENCE, seed=seed, severity=0.8)
        alignment = metrics.align(metrics.normalize(SENTENCE), metrics.normalize(produced))
        assert alignment.deletions == 0, produced
        assert alignment.substitutions == 0, produced


def test_strip_formatting_removes_case_and_punctuation():
    text, operations = inject(SENTENCE, seed=2, severity=0.3, strip_formatting=True)
    assert text == text.lower()
    assert "." not in text
    assert "strip_formatting" in operations


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------


def test_identical_text_scores_perfectly():
    scored = metrics.score(SENTENCE, SENTENCE)
    assert scored.content == scored.format == scored.blend == 1.0


def test_case_and_punctuation_split_the_two_axes():
    scored = metrics.score("Ship it on Friday.", "ship it on friday")
    assert scored.content == 1.0
    assert scored.format < 1.0


def test_a_perfect_cleanup_beats_the_uncleaned_transcript():
    messy = disfluent(SENTENCE, seed=9, severity=0.7)
    assert metrics.score(SENTENCE, SENTENCE).blend > metrics.score(SENTENCE, messy).blend


def test_score_is_floored_at_zero():
    scored = metrics.score("yes", "a completely unrelated sentence that rambles on and on")
    assert scored.content == 0.0
    assert scored.blend >= 0.0


def test_empty_hypothesis_loses_every_word():
    assert metrics.score(SENTENCE, "").content == 0.0


def test_alignment_reports_the_actual_diff():
    alignment = metrics.align(["ship", "it", "friday"], ["um", "ship", "it", "monday"])
    assert (alignment.insertions, alignment.substitutions, alignment.deletions) == (1, 1, 0)
    assert "um" in alignment.inserted
    assert ("friday", "monday") in alignment.substituted


def test_unknown_axis_is_rejected():
    with pytest.raises(ValueError):
        metrics.score(SENTENCE, SENTENCE).value("vibes")


def test_mean_of_no_scores_is_zero_on_every_axis():
    assert metrics.mean([]) == dict.fromkeys(metrics.AXES, 0.0)


# --------------------------------------------------------------------------
# Feedback — derived from the pair, not from a fixed filler list
# --------------------------------------------------------------------------


def test_feedback_names_a_leftover_word_that_came_from_the_input():
    reference, source = "Ship it on Friday.", "Um, ship it on Friday."
    hypothesis = "Um, ship it on Friday."
    note = metrics.feedback(reference, hypothesis, source, metrics.score(reference, hypothesis))
    assert "left disfluencies" in note
    assert "um" in note.lower()


def test_feedback_distinguishes_invented_words_from_leftover_ones():
    """A word in neither the input nor the target is a hallucination, not a leftover."""
    reference, source = "Ship it on Friday.", "Ship it on Friday."
    hypothesis = "Ship it on Friday urgently."
    note = metrics.feedback(reference, hypothesis, source, metrics.score(reference, hypothesis))
    assert "added words that were not in the transcript" in note
    assert "left disfluencies" not in note


def test_feedback_works_for_disfluencies_no_filler_list_would_contain():
    """The corpus decides what a disfluency is — real transcripts aren't enumerable."""
    reference = "We should go on Thursday."
    source = "We should uhh go on go on Thursday."
    hypothesis = "We should uhh go on Thursday."
    note = metrics.feedback(reference, hypothesis, source, metrics.score(reference, hypothesis))
    assert "uhh" in note


def test_feedback_names_dropped_content():
    reference, source = "Ship the revised build on Friday.", "Ship the revised build on Friday."
    hypothesis = "Ship on Friday."
    note = metrics.feedback(reference, hypothesis, source, metrics.score(reference, hypothesis))
    assert "dropped content words" in note


def test_feedback_on_a_perfect_cleanup_is_not_empty():
    note = metrics.feedback(SENTENCE, SENTENCE, SENTENCE, metrics.score(SENTENCE, SENTENCE))
    assert note.strip()


# --------------------------------------------------------------------------
# De-tagging real corpus conventions
# --------------------------------------------------------------------------


def test_detag_rewrites_the_nyra_conventions():
    verbatim = "I mean we we [UH] should go on th* Thursday [laughter]"
    assert corpus._detag_nyra(verbatim) == "I mean we we uh should go on th- Thursday"


def test_detag_keeps_spoken_fillers_and_drops_sound_events():
    assert corpus._detag_nyra("[UM] okay [breath] then") == "um okay then"


def test_detag_leaves_ordinary_text_alone():
    assert corpus._detag_nyra("we should go on Thursday") == "we should go on Thursday"


# --------------------------------------------------------------------------
# Corpus loading
# --------------------------------------------------------------------------


def test_builtin_corpus_loads_offline_and_injects():
    loaded = corpus.load(source="builtin", limit=5, seed=1)
    assert len(loaded) == 5
    assert loaded.detail["injected"] is True
    assert all(u.operations for u in loaded.utterances)
    assert loaded.disfluent_fraction == 1.0


def test_paired_sources_are_registered_with_both_columns():
    for key in ("disfluency-speech", "nyra", "disfl-qa"):
        source = corpus.SOURCES[key]
        assert source.is_paired
        assert len(source.fields) == 2


def test_split_override_reaches_the_loader(monkeypatch):
    """Large runs need `train`; the held-out splits are only a few hundred rows."""
    seen = {}

    def fake_rows(spec, limit):
        seen["split"] = spec.split
        return iter(())

    monkeypatch.setattr(corpus, "_rows_via_api", fake_rows)
    with pytest.raises(RuntimeError):  # no rows, so the corpus is empty
        corpus.load(source="disfluency-speech", limit=5, split="train")
    assert seen["split"] == "train"


def test_split_defaults_to_the_sources_own_choice(monkeypatch):
    seen = {}

    def fake_rows(spec, limit):
        seen["split"] = spec.split
        return iter(())

    monkeypatch.setattr(corpus, "_rows_via_api", fake_rows)
    with pytest.raises(RuntimeError):
        corpus.load(source="disfluency-speech", limit=5)
    assert seen["split"] == corpus.SOURCES["disfluency-speech"].split


def test_fleurs_is_reference_only():
    assert not corpus.SOURCES["fleurs"].is_paired


def test_unknown_source_is_rejected():
    with pytest.raises(ValueError):
        corpus.load(source="nope", limit=5)


def test_injection_sources_require_punctuated_references():
    assert corpus._usable_reference(
        "Long enough and ends properly right here now.", for_injection=True
    )
    assert not corpus._usable_reference(
        "no terminal punctuation on this one here", for_injection=True
    )
    assert not corpus._usable_reference("Too short.", for_injection=True)


def test_paired_sources_accept_short_unpunctuated_references():
    """Real conversational targets are neither long nor punctuated."""
    assert corpus._usable_reference("we should go on thursday", for_injection=False)


def test_jsonl_accepts_pairs_and_bare_references(tmp_path):
    path = tmp_path / "refs.jsonl"
    path.write_text(
        '{"disfluent": "um ship it on friday", "reference": "Ship it on Friday."}\n'
        "Please send the revised figures over before tomorrow's review meeting.\n",
        encoding="utf-8",
    )
    loaded = corpus.load(jsonl=str(path), limit=10, seed=1)
    assert loaded.source == "jsonl"
    assert len(loaded) == 2
    # The supplied pair is kept verbatim; the bare reference gets injected.
    assert loaded.utterances[0].disfluent == "um ship it on friday"
    assert loaded.utterances[1].disfluent != loaded.utterances[1].reference


def test_corpus_deduplicates_by_reference():
    loaded = corpus.load(source="builtin", limit=100, seed=1)
    assert len({u.reference for u in loaded.utterances}) == len(loaded)


# --------------------------------------------------------------------------
# Splitting, floors, and axis resolution
# --------------------------------------------------------------------------


def test_splits_are_disjoint_and_complete():
    loaded = corpus.load(source="builtin", limit=12, seed=4)
    train, dev, test = corpus.split(list(loaded.utterances), 4, 0.3, 0.3)
    everything = train + dev + test
    assert len(everything) == len(loaded)
    assert len({u.reference for u in everything}) == len(loaded)


def test_splitting_is_stable_for_a_seed():
    loaded = corpus.load(source="builtin", limit=12, seed=4)
    first = corpus.split(list(loaded.utterances), 4, 0.3, 0.3)
    second = corpus.split(list(loaded.utterances), 4, 0.3, 0.3)
    assert [u.reference for u in first[2]] == [u.reference for u in second[2]]


def test_no_cleanup_floor_sits_below_a_perfect_cleanup():
    loaded = corpus.load(source="builtin", limit=12, seed=6, severity=0.5)
    floor = corpus.no_cleanup_floor(list(loaded.utterances))
    assert 0.0 < floor["blend"] < 1.0


def _corpus(measurable: bool) -> corpus.Corpus:
    return corpus.Corpus(
        utterances=(), source="disfluency-speech", detail={}, formatting_is_measurable=measurable
    )


def test_unmeasurable_formatting_downgrades_blend_to_content():
    assert cli.resolve_axis("blend", _corpus(False)) == "content"
    assert cli.resolve_axis("content", _corpus(False)) == "content"


def test_explicit_format_axis_is_refused_when_it_cannot_be_measured():
    with pytest.raises(SystemExit):
        cli.resolve_axis("format", _corpus(False))


def test_measurable_formatting_keeps_the_requested_axis():
    assert all(cli.resolve_axis(axis, _corpus(True)) == axis for axis in metrics.AXES)


def test_the_repaired_repackaging_can_measure_formatting():
    """nyra recases its targets, which is the whole reason to prefer it over upstream."""
    assert corpus.SOURCES["nyra"].formatting_is_measurable
    assert not corpus.SOURCES["disfluency-speech"].formatting_is_measurable


def test_upstream_pair_reads_the_hand_annotated_columns():
    source = corpus.SOURCES["disfluency-speech"]
    assert (source.input_field, source.target_field) == ("transcript_a", "transcript_c")
    # transcript_a is already transcriber-shaped, so nothing needs undoing.
    assert source.detag is None


# --------------------------------------------------------------------------
# Hugging Face auth
# --------------------------------------------------------------------------


def test_env_token_is_used(monkeypatch):
    monkeypatch.setenv("HF_TOKEN", "hf_from_env")
    assert corpus.hf_token() == "hf_from_env"


def test_legacy_env_name_still_works(monkeypatch):
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.setenv("HUGGING_FACE_HUB_TOKEN", "hf_legacy")
    assert corpus.hf_token() == "hf_legacy"


def test_cli_login_token_file_is_read(monkeypatch, tmp_path):
    """`hf auth login` writes a file, not a variable — the thing people actually run."""
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.delenv("HUGGING_FACE_HUB_TOKEN", raising=False)
    monkeypatch.delenv("HF_TOKEN_PATH", raising=False)
    monkeypatch.setenv("HF_HOME", str(tmp_path))
    (tmp_path / "token").write_text("hf_from_login\n", encoding="utf-8")
    assert corpus.hf_token() == "hf_from_login"


def test_explicit_token_path_is_honoured(monkeypatch, tmp_path):
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.delenv("HUGGING_FACE_HUB_TOKEN", raising=False)
    path = tmp_path / "elsewhere"
    path.write_text("hf_explicit", encoding="utf-8")
    monkeypatch.setenv("HF_TOKEN_PATH", str(path))
    assert corpus.hf_token() == "hf_explicit"


def test_env_token_wins_over_the_login_file(monkeypatch, tmp_path):
    monkeypatch.setenv("HF_HOME", str(tmp_path))
    (tmp_path / "token").write_text("hf_from_login", encoding="utf-8")
    monkeypatch.setenv("HF_TOKEN", "hf_from_env")
    assert corpus.hf_token() == "hf_from_env"


def test_no_token_anywhere_is_not_an_error(monkeypatch, tmp_path):
    """Anonymous access still works — it is only rate limited."""
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.delenv("HUGGING_FACE_HUB_TOKEN", raising=False)
    monkeypatch.delenv("HF_TOKEN_PATH", raising=False)
    monkeypatch.setenv("HF_HOME", str(tmp_path / "empty"))
    assert corpus.hf_token() is None


def test_blank_token_file_is_ignored(monkeypatch, tmp_path):
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.delenv("HUGGING_FACE_HUB_TOKEN", raising=False)
    monkeypatch.delenv("HF_TOKEN_PATH", raising=False)
    monkeypatch.setenv("HF_HOME", str(tmp_path))
    (tmp_path / "token").write_text("   \n", encoding="utf-8")
    assert corpus.hf_token() is None


# --------------------------------------------------------------------------
# Progress meter
# --------------------------------------------------------------------------


class _Pipe(io.StringIO):
    """A stream that is explicitly not a terminal."""

    def isatty(self) -> bool:
        return False


class _Terminal(io.StringIO):
    def isatty(self) -> bool:
        return True


def test_piped_output_uses_newlines_not_carriage_returns():
    """A log file full of \r is one unreadable line — the failure mode to avoid."""
    stream = _Pipe()
    meter = progress.Progress(20, "work", stream=stream)
    for _ in range(20):
        meter.tick()
    meter.close()
    assert "\r" not in stream.getvalue()
    assert stream.getvalue().count("\n") > 1


def test_piped_output_reports_deciles_not_every_tick():
    stream = _Pipe()
    meter = progress.Progress(100, "work", stream=stream)
    for _ in range(100):
        meter.tick()
    # Ten deciles, not a hundred lines.
    assert stream.getvalue().count("progress ") == 10


def test_terminal_output_rewrites_one_line_in_place():
    stream = _Terminal()
    meter = progress.Progress(10, "work", stream=stream)
    for _ in range(10):
        meter.tick()
    body = stream.getvalue()
    assert body.count("\r") >= 10
    assert "█" in body


def test_meter_reaches_exactly_the_total_and_never_exceeds_it():
    stream = _Pipe()
    meter = progress.Progress(5, stream=stream)
    for _ in range(9):  # more ticks than units, e.g. a retry
        meter.tick()
    assert meter.done == 5


def test_zero_total_does_not_divide_by_zero():
    meter = progress.Progress(0, stream=_Pipe())
    meter.tick()
    meter.close()


def test_eta_is_unknown_before_the_first_tick():
    assert progress.Progress(10, stream=_Pipe())._eta() == "—"


def test_durations_read_at_a_glance():
    assert progress._duration(18) == "18s"
    assert progress._duration(262) == "4m22s"
    assert progress._duration(3720) == "1h02m"


@pytest.mark.skipif(
    importlib.util.find_spec("dspy") is None, reason="the only test that needs DSPy installed"
)
def test_a_failing_example_still_advances_the_meter():
    """A meter that stalls on the first failure is worse than no meter."""
    # The one test in this file that needs DSPy installed: `_Ticking` subclasses
    # `dspy.Module` (that is what lets `dspy.Parallel` call it), so it can't move
    # out of the DSPy-only module and be tested from a bare interpreter. Skip
    # rather than fail where DSPy is absent — every other test here, and
    # `--dry-run`, still run on the standard library alone, which is what lets
    # scripts/check.sh gate on this suite.
    pytest.importorskip("dspy")
    ticks = []

    class Boom:
        def __call__(self, **_):
            raise RuntimeError("upstream refused")

    import program as program_module

    wrapped = program_module._Ticking(Boom(), lambda: ticks.append(1))
    with pytest.raises(RuntimeError):
        wrapped(raw_transcript="x")
    assert ticks == [1]


# --------------------------------------------------------------------------
# Candidates and the offline guarantee
# --------------------------------------------------------------------------


def test_the_in_harness_baseline_is_labelled_as_a_guess():
    """It guesses the server's wording and runs on our stand-in model — say so."""
    assert candidates.BASELINE == "guessed-default"
    assert "guess" in candidates.__doc__.lower()


def test_every_candidate_instruction_is_shippable():
    assert candidates.BASELINE in candidates.CANDIDATES
    for name, instruction in candidates.CANDIDATES.items():
        assert instruction.strip(), name
        # The API's cap on config.llm.instruction, not the 4096 one on config.prompt.
        # Asserting the prompt's figure here is the bug this file now guards: it let a
        # 3057-character instruction pass every test and 400 every real request.
        assert candidates.overage(instruction) == 0, name
        # A second, tighter bound that is the eval's own: hand-written candidates stay
        # readable as a single instruction. The optimizer's output is not held to it.
        assert len(instruction) < 1000, name


def test_the_cap_is_the_instruction_field_s_own_not_the_prompt_s():
    """These two limits are different numbers on the same request; conflating them broke dictation."""
    assert candidates.INSTRUCTION_CHARACTER_CAP == 2048


def test_overage_reports_the_distance_past_the_cap():
    cap = candidates.INSTRUCTION_CHARACTER_CAP
    assert candidates.overage("x" * cap) == 0
    assert candidates.overage("x" * (cap - 1)) == 0
    assert candidates.overage("x" * (cap + 7)) == 7


def test_the_prior_winner_is_a_seed_and_not_a_candidate():
    """It is kept precisely because it doesn't fit — pruning it is what --start is for."""
    assert candidates.PRIOR_WINNER not in candidates.CANDIDATES.values()
    assert candidates.overage(candidates.PRIOR_WINNER) > 0


def test_an_oversized_candidate_stops_the_run_before_any_model_call(monkeypatch):
    """The check is worth having only if it fires before the sweep spends money."""
    monkeypatch.setitem(candidates.CANDIDATES, "too-long", "x" * 5000)
    with pytest.raises(SystemExit) as raised:
        cli.check_candidate_lengths()
    assert "too-long" in str(raised.value)
    assert "2048" in str(raised.value)


def test_candidate_length_check_passes_as_shipped():
    assert cli.check_candidate_lengths() is None


def test_describe_length_names_the_overage_or_the_headroom():
    cap = candidates.INSTRUCTION_CHARACTER_CAP
    assert "9 OVER" in cli.describe_length("x" * (cap + 9))
    assert "9 under" in cli.describe_length("x" * (cap - 9))


def test_the_instruction_budget_reaches_the_gepa_feedback_text():
    """GEPA's reflector reads only this string, so an unstated cap is an invisible one."""
    scored = metrics.score("the build failed", "the build, uh, failed")
    without = metrics.feedback("the build failed", "the build, uh, failed", "x", scored)
    with_budget = metrics.feedback(
        "the build failed", "the build, uh, failed", "x", scored, instruction_budget=2048
    )
    assert "2048" not in without
    assert "at most 2048 characters" in with_budget


def test_the_budget_rides_on_a_perfect_score_too():
    """The instruction can grow on a run where nothing is failing — say the cap anyway."""
    perfect = metrics.score("identical text", "identical text")
    message = metrics.feedback(
        "identical text", "identical text", "x", perfect, instruction_budget=2048
    )
    assert "Perfect" in message
    assert "at most 2048 characters" in message


def test_dry_run_never_reaches_the_dspy_module():
    """The offline promise is structural: the deferred import must not fire.

    Asserting on `dspy` itself would be flaky — any other test that imports
    `program` puts it in `sys.modules` for the whole session. The property that
    actually matters is that the dry-run path never touches `program`, which is
    the only module allowed to import DSPy (pinned by the test below).
    """
    sys.modules.pop("program", None)
    assert (
        cli.main(["--source", "builtin", "--dry-run", "--limit", "12", "--show-samples", "1"]) == 0
    )
    assert "program" not in sys.modules


def test_program_is_the_only_module_that_imports_dspy():
    """Keeps the offline guarantee from eroding one convenience import at a time."""
    here = pathlib.Path(__file__).parent
    offenders = [
        path.name
        for path in sorted(here.glob("*.py"))
        if path.name not in {"program.py", "test_eval.py"}
        and re.search(r"^\s*(import dspy|from dspy)", path.read_text(), re.MULTILINE)
    ]
    assert offenders == []
