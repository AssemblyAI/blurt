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


def test_worse_than_silence_scores_below_zero_and_stays_ordered():
    """Flattening every catastrophe to 0.0 left GEPA's per-example front unable to rank them."""
    mild = metrics.from_error_rate(1.2)
    bad = metrics.from_error_rate(2.9)
    catastrophic = metrics.from_error_rate(4.3)
    assert 0.0 > mild > bad > catastrophic > metrics.WORST_SCORE


def test_the_normal_range_is_untouched_so_old_numbers_still_compare():
    """The change may only add ordering below zero; a 0.848 run has to stay 0.848."""
    for rate in (0.0, 0.15, 0.5, 0.99, 1.0):
        assert metrics.from_error_rate(rate) == 1.0 - rate


def test_the_two_pieces_meet_without_a_step():
    """A discontinuity at WER 1 would be a ledge for the optimizer to sit on.

    Both sides have slope -1 there, so across a 2e-of-nothing window the outputs may
    differ by about that much and no more — a step would show as a constant offset
    surviving however small the window gets.
    """
    assert metrics.from_error_rate(1.0) == 0.0
    for epsilon in (1e-3, 1e-5, 1e-7):
        gap = metrics.from_error_rate(1 - epsilon) - metrics.from_error_rate(1 + epsilon)
        assert gap == pytest.approx(2 * epsilon, rel=1e-3), epsilon


def test_the_tail_is_bounded_so_a_crash_can_still_be_the_worst_outcome():
    """GEPA scores a failed rollout with a fixed value; real output must not sink past it."""
    assert metrics.from_error_rate(1e6) >= metrics.WORST_SCORE


def test_empty_hypothesis_is_exactly_zero():
    """Zero keeps its meaning: as bad as saying nothing, which is a WER of exactly 1."""
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
    for key in ("nyra",):
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
        corpus.load(source="nyra", limit=5, split="train")
    assert seen["split"] == "train"


def test_split_defaults_to_the_sources_own_choice(monkeypatch):
    seen = {}

    def fake_rows(spec, limit):
        seen["split"] = spec.split
        return iter(())

    monkeypatch.setattr(corpus, "_rows_via_api", fake_rows)
    with pytest.raises(RuntimeError):
        corpus.load(source="nyra", limit=5)
    assert seen["split"] == corpus.SOURCES["nyra"].split


def test_every_registered_source_is_paired():
    """Reference-only sources score disfluencies this repo invented, not ones speakers made.

    `google/fleurs` was the last of them and was removed: read speech has no disfluent
    side, so the injector's filler list doubled as the answer key. Injection survives
    only for `--source builtin`, the offline smoke path.
    """
    assert all(s.is_paired for s in corpus.SOURCES.values())


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
        utterances=(), source="a-corpus", detail={}, formatting_is_measurable=measurable
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
    """Recased targets are the whole reason this repackaging is the one kept.

    Its upstream, `amaai-lab/DisfluencySpeech`, builds its clean side by stripping
    markup mechanically, which leaves the word after a removed span lowercase — so
    formatting there scores a correct cleanup as wrong.
    """
    assert corpus.SOURCES["nyra"].formatting_is_measurable


def test_the_paired_source_reads_both_repackaged_columns_and_undoes_its_markup():
    source = corpus.SOURCES["nyra"]
    assert (source.input_field, source.target_field) == (
        "verbatim_transcript",
        "intended_transcript",
    )
    # Unlike its upstream, this side is written in the corpus's own conventions
    # (`[UH]`, `[laughter]`, `th*`), so it has to be rewritten as transcript text.
    assert source.detag is corpus._detag_nyra


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


def test_the_baseline_is_the_best_instruction_we_have():
    """The bar a search must clear is what we would otherwise ship, not a floor."""
    assert candidates.BASELINE == "prior-winner"
    assert candidates.CANDIDATES[candidates.BASELINE] == candidates.PRIOR_WINNER


def test_the_guessed_default_survives_as_a_floor_and_is_labelled_a_guess():
    """It guesses the server's wording and runs on our stand-in model — say so.

    It stopped being `BASELINE` once a measured instruction existed to compare
    against, but beating a terse instruction is still the cheapest sign that a corpus
    and model pairing can tell instructions apart at all.
    """
    assert "guessed-default" in candidates.CANDIDATES
    assert "guess" in candidates.__doc__.lower()


def test_every_candidate_instruction_is_shippable():
    assert candidates.BASELINE in candidates.CANDIDATES
    for name, instruction in candidates.CANDIDATES.items():
        assert instruction.strip(), name
        # The API's cap on config.llm.instruction, not the 4096 one on config.prompt.
        # Asserting the prompt's figure here is the bug this file now guards: it let a
        # 3057-character instruction pass every test and 400 every real request.
        assert candidates.overage(instruction) == 0, name
        # A second, tighter bound that is the eval's own: a hand-written candidate is a
        # single readable instruction. `prior-winner` is exempt because it is not
        # hand-written — it is an evolved instruction, and its length is the API's
        # business, not a style rule's.
        if name != "prior-winner":
            assert len(instruction) < 1000, name


def test_the_cap_is_the_instruction_field_s_own_not_the_prompt_s():
    """These two limits are different numbers on the same request; conflating them broke dictation."""
    assert candidates.INSTRUCTION_CHARACTER_CAP == 2048


def test_overage_reports_the_distance_past_the_cap():
    cap = candidates.INSTRUCTION_CHARACTER_CAP
    assert candidates.overage("x" * cap) == 0
    assert candidates.overage("x" * (cap - 1)) == 0
    assert candidates.overage("x" * (cap + 7)) == 7


def test_the_prior_winner_fits_and_so_is_a_shippable_candidate():
    """It was 1009 characters over and unshippable; compressed, it is the thing to beat."""
    assert candidates.overage(candidates.PRIOR_WINNER) == 0
    assert candidates.PRIOR_WINNER in candidates.CANDIDATES.values()


def test_the_compressed_winner_kept_the_product_critical_safeguards():
    """Compression cut duplicates; these three clauses are not negotiable.

    Dictating "what time is it?" into a text field has to paste the question back,
    not an answer to it — an instruction-following model handed a bare transcript
    will otherwise treat it as a request. Same for translation: non-English speech
    has to survive as spoken. These were asserted on the Swift constant before the
    revert; they live here now.
    """
    for clause in ("answer the text", "translate", "rephrase"):
        assert clause in candidates.PRIOR_WINNER, clause


def test_the_stated_target_sits_below_the_cap_that_is_enforced():
    """Told "at most 2048", one run's rejects had a median length of 2149.

    A model aims at the number it is handed, so the number it is handed is no longer
    the number enforced — but a proposal between the two is still accepted, since the
    target is advice and only the cap is real.
    """
    cap = candidates.INSTRUCTION_CHARACTER_CAP
    assert candidates.target_length(cap) < cap
    assert candidates.word_budget(cap) < cap / candidates.CHARS_PER_WORD
    between = "x " * ((candidates.target_length(cap) + cap) // 2 // 2)
    assert candidates.overage(between) == 0


def test_the_seed_leaves_the_search_room_to_work():
    """A seed that scores well and cannot be improved is worth less than a weaker one.

    Reflectors returned drafts 630-890 characters longer than an 1839-character seed,
    so nearly every proposal broke the cap and one run spent 8 of 9 iterations
    re-scoring what it started with. The headroom has to cover that natural expansion,
    or the search only appears to run.
    """
    headroom = candidates.INSTRUCTION_CHARACTER_CAP - len(candidates.PRIOR_WINNER)
    # 400 rather than the 600 an earlier, shorter seed left. Each winning seed is
    # longer than the one before, so this ratchets down; below ~400 a reflector's
    # typical expansion lands outside the cap and the proposer spends the run
    # rejecting and trimming instead of searching.
    assert headroom >= 400, f"only {headroom} characters of room for the search"


def test_the_seed_carries_no_dangling_rule_numbering():
    """The numbered block was dropped whole, so no orphaned "2." should survive."""
    body = [line for line in candidates.PRIOR_WINNER.split("\n") if line.strip()]
    assert not [line for line in body if re.match(r"^\d+\. ", line)]


def test_an_oversized_candidate_stops_the_run_before_any_model_call(monkeypatch):
    """The check is worth having only if it fires before the sweep spends money."""
    monkeypatch.setitem(candidates.CANDIDATES, "too-long", "x" * 5000)
    with pytest.raises(SystemExit) as raised:
        cli.check_candidates()
    assert "too-long" in str(raised.value)
    assert "2048" in str(raised.value)


def test_candidate_length_check_passes_as_shipped():
    assert cli.check_candidates() is None


def test_describe_length_names_the_overage_or_the_headroom():
    cap = candidates.INSTRUCTION_CHARACTER_CAP
    assert "9 OVER" in cli.describe_length("x" * (cap + 9))
    assert "9 under" in cli.describe_length("x" * (cap - 9))


def test_the_feedback_reports_only_the_axis_being_selected_on():
    """Naming an axis nobody selects on points the search at noise.

    A corpus whose target casing is a mechanical artifact makes the harness degrade
    `blend` to `content` — so telling the reflector a formatting score there invites it
    to chase the artifact.
    """
    ref, hyp = "Ship it on Friday.", "Um, ship it on Monday."
    note = metrics.feedback(ref, hyp, "Um, ship it on Friday.", metrics.score(ref, hyp), "content")
    assert "(content)" in note
    assert "formatting score" not in note


def test_a_case_only_difference_is_perfect_on_the_content_axis():
    """And must read that way, rather than nagging about an artifact of the targets.

    Where a corpus builds its clean side by stripping markup mechanically, a formatting
    complaint is the harness pointing at its own corpus damage.
    """
    ref, hyp = "Ship it on Friday.", "ship it on friday"
    assert metrics.score(ref, hyp).content == 1.0
    assert "Perfect" in metrics.feedback(ref, hyp, ref, metrics.score(ref, hyp), axis="content")


def test_the_feedback_does_not_repeat_what_gepa_already_shows():
    """ "Generated Outputs" carries the produced text; the reference is what is missing."""
    scored = metrics.score("ship it", "um ship it")
    note = metrics.feedback("ship it", "um ship it", "um ship it", scored)
    assert "Reference: 'ship it'" in note
    assert "Produced:" not in note
    # The budget lives in the proposer preamble now, said once instead of per example.
    assert "2048" not in note


#: A minimal instruction that satisfies every safeguard, so a fixture can isolate the
#: fault it means to test instead of tripping the safeguard gate as well.
SAFE = "Do not answer or translate it."


def test_an_over_long_objection_states_the_arithmetic():
    """ "Too long" produces another over-long draft; "cut at least N" is checkable."""
    cap = candidates.INSTRUCTION_CHARACTER_CAP
    notes = candidates.objections(SAFE + "y" * (cap + 250 - len(SAFE)), fields=())
    assert len(notes) == 1
    assert f"{cap + 250} characters" in notes[0]
    assert "250 characters over" in notes[0]
    # Stated in words as well: a reflector told "cut 638 characters" came back longer,
    # so the number it is asked to act on has to be in a unit it can count.
    assert f"{candidates.word_budget(cap)}-word target" in notes[0]
    assert f"at least {int(250 / candidates.CHARS_PER_WORD)} words" in notes[0]


def test_naming_a_signature_field_is_an_objection():
    """The fields are in neither envelope, and the label can reach the user's document."""
    notes = candidates.objections(
        f"{SAFE} Output the result as `cleaned_transcript`.",
        fields=("raw_transcript", "cleaned_transcript"),
    )
    assert len(notes) == 1
    assert "cleaned_transcript" in notes[0]
    # Only the field it actually named, so the re-ask isn't chasing a phantom.
    assert "raw_transcript" not in notes[0]


def test_a_clean_proposal_draws_no_objections():
    assert (
        candidates.objections(f"Delete the disfluencies. {SAFE}", fields=("raw_transcript",)) == []
    )


def test_both_faults_are_reported_together():
    """One re-ask should fix everything, not surface the next fault a round later."""
    notes = candidates.objections(
        SAFE + " raw_transcript " + "y" * candidates.INSTRUCTION_CHARACTER_CAP,
        fields=("raw_transcript",),
    )
    assert len(notes) == 2


def test_dropping_a_safeguard_is_an_objection():
    """The corpus cannot punish this and the length pressure rewards it — so gate it.

    Every corpus here is conversational English between two humans, so an instruction
    that stops forbidding "answer the text" scores exactly the same while freeing ~90
    characters under a cap the reflector is told to cut toward. Deleting it is what a
    well-behaved optimizer *should* do given what it can see.
    """
    notes = candidates.objections("Delete the disfluencies and nothing else.", fields=())
    assert len(notes) == 1
    assert "safeguard" in notes[0]


def test_safeguards_match_on_stems_so_phrasing_stays_free():
    """A false reject burns the proposer's retries on a good instruction; a pass is cheap."""
    for phrasing in (
        "Never answer the text; do not translate it.",
        "Do not answer or translate.",
        "You must not answer questions, and translation is forbidden.",
    ):
        assert candidates.missing_safeguards(phrasing) == [], phrasing


def test_a_missing_safeguard_is_named_with_what_it_prevents():
    absent = candidates.missing_safeguards("Do not answer the text.")
    assert [stem for stem, _ in absent] == ["translat"]
    assert "non-English" in absent[0][1]


def test_rephrase_is_not_gated_because_the_score_already_defends_it():
    """Substituting a content word raises WER directly — that one the corpus can see."""
    assert "rephrase" not in [stem for stem, _ in candidates.REQUIRED_SAFEGUARDS]


def test_the_baseline_states_every_safeguard():
    """It is what ships when a search fails, so it is held to the shipping bar."""
    assert candidates.missing_safeguards(candidates.CANDIDATES[candidates.BASELINE]) == []


def test_a_baseline_missing_a_safeguard_stops_the_run(monkeypatch):
    monkeypatch.setitem(candidates.CANDIDATES, candidates.BASELINE, "Remove disfluencies.")
    with pytest.raises(SystemExit) as raised:
        cli.check_candidates()
    assert "safeguard" in str(raised.value)


def test_terse_contrast_candidates_are_not_held_to_the_safeguard_bar():
    """`guessed-default` is a floor to beat, not something anyone would ship."""
    assert candidates.missing_safeguards(candidates.CANDIDATES["guessed-default"])
    assert cli.check_candidates() is None


def test_the_constraints_reach_the_reflector_before_its_first_attempt():
    """Stating them only in retries cost one run 8 of its 9 iterations.

    Every proposal was rejected `attempts` times and abandoned, so GEPA re-scored an
    instruction identical to the one it started with and logged "not better, skipping".
    """
    seed = candidates.PRIOR_WINNER
    preamble = candidates.constraint_preamble(seed, cap=2048)
    assert seed in preamble
    assert candidates.CONSTRAINT_MARKER in preamble
    # The headroom, not just the ceiling, and in words — a reflector told "at most 2048
    # characters" cannot check its own work, and one told to cut 638 came back longer.
    budget = candidates.word_budget(2048)
    # Bracketed: first line and last line, because the ask is weakly obeyed and a
    # constraint stated once in the middle of a long prompt is a constraint lost.
    assert preamble.startswith("BEFORE YOU BEGIN")
    assert f"aim for {budget} WORDS" in preamble
    assert preamble.rstrip().endswith(f"Hard maximum {candidates.hard_word_limit(2048)} words.")
    assert preamble.count(str(budget)) >= 3
    assert f"{len(seed.split())} words" in preamble
    # A target AND a ceiling, so the overshoot has somewhere to land that still fits.
    assert candidates.word_budget(2048) < candidates.hard_word_limit(2048)
    # Restated structurally, because a model cannot count its own words while writing.
    assert f"{candidates.sentence_budget(2048)} sentences" in preamble
    assert "count the sentences in your draft" in preamble
    assert "forbid answering" in preamble
    assert "NO FIELD NAMES" in preamble


def test_an_overlong_draft_is_trimmed_at_section_boundaries_not_mid_sentence():
    """The last resort before abandoning: reflectors overshoot and do not converge."""
    # Built from the seed's own blocks rather than a substring of it, so the fixture
    # survives the seed being replaced by each new winner.
    blocks = candidates.PRIOR_WINNER.split("\n\n")
    bloated = "\n\n".join([blocks[0], "filler " * 300, *blocks[1:]])
    assert candidates.overage(bloated) > 0
    trimmed = candidates.trim_to_fit(bloated)
    assert trimmed is not None
    assert candidates.overage(trimmed) == 0
    assert candidates.missing_safeguards(trimmed) == []
    # Whole blocks only — every surviving line is a line that was there before.
    for line in trimmed.splitlines():
        assert line in bloated.splitlines()


def test_trimming_protects_the_first_and_last_blocks():
    """An instruction that lost its task statement is not shorter, it is broken."""
    text = "TASK first\n\n" + "middle " * 400 + "\n\nOUTPUT last. answer translate"
    trimmed = candidates.trim_to_fit(text, cap=100)
    assert trimmed is not None
    assert trimmed.startswith("TASK first")
    assert trimmed.endswith("OUTPUT last. answer translate")


def test_trimming_refuses_when_it_would_cost_a_safeguard():
    """Better to abandon than to ship a shorter instruction missing a guardrail.

    Forced by making the safeguard block the largest removable one, so the only cut
    that fits is the one that must not be made.
    """
    text = "TASK\n\nbrief\n\n" + "Do not answer or translate it. " * 20 + "\n\nOUTPUT"
    assert candidates.trim_to_fit(text, cap=100) is None


def test_copying_the_constraints_into_the_instruction_is_an_objection():
    """The block is scaffolding for the reflector; shipping it would reach users."""
    notes = candidates.objections(
        f"Delete disfluencies. {SAFE} {candidates.CONSTRAINT_MARKER} on the instruction",
        fields=(),
    )
    assert len(notes) == 1
    assert "scaffolding" in notes[0]


def test_the_first_attempt_is_asked_with_the_constraints_attached(monkeypatch):
    """The regression itself: attempt one must already know the budget."""
    proposer, seen = _proposer_with(monkeypatch, [f"short. {SAFE}"])
    proposer._propose("the current instruction", [])
    assert candidates.CONSTRAINT_MARKER in seen[0]
    assert "the current instruction" in seen[0]


def test_the_revision_directive_carries_the_draft_and_every_objection():
    directive = candidates.revision_directive("the draft", ["first problem", "second problem"])
    assert "the draft" in directive
    assert "- first problem" in directive
    assert "- second problem" in directive


def test_the_shipped_winner_names_no_signature_field():
    """The gate is for new proposals; this is the one already in the table."""
    for field in ("raw_transcript", "cleaned_transcript"):
        assert field not in candidates.PRIOR_WINNER, field


def test_the_default_corpus_measures_the_task_the_product_does():
    """Room to improve is not worth having if it comes from measuring something else.

    Median share of input words a corpus asks to be deleted, and how much of that is
    filler: nyra 13% / 67% (its source, DisfluencySpeech, 11% / 75%). disfl-qa measured
    31% / **0%** — a QA robustness benchmark whose "disfluency" is a distractor
    harvested from the source paragraph — and was removed for that reason, so this
    also guards against it being registered again.
    """
    assert cli.parse_args([]).source == "nyra"
    assert "disfl-qa" not in corpus.SOURCES


def test_the_default_corpus_can_measure_formatting():
    """So `blend` uses both axes instead of degrading to content, as it does on Switchboard."""
    assert corpus.SOURCES[cli.parse_args([]).source].formatting_is_measurable


def test_a_bare_invocation_is_the_recommended_gepa_run():
    """Running with no flags now spends money — pin what it spends it on."""
    args = cli.parse_args([])
    assert (args.optimizer, args.start, args.auto) == ("gepa", "prior-winner", "heavy")
    assert args.api_base == "https://llm-gateway.assemblyai.com/v1"
    # The plain adapter is no longer selectable: the service's rewrite runs under a ~5s
    # budget so the stand-in is small, and small models cannot follow the field-marker
    # protocol at all. There was never a run that wanted the other one.
    assert not hasattr(args, "adapter")
    # A 4B model writing its own instructions is the weakest link in the loop.
    assert args.reflection_model != args.model


def _default_split(argv=()):
    """train / optimizer valset / dev / test, the way `main` carves them."""
    args = cli.parse_args(list(argv))
    train, dev, test = corpus.split(
        list(range(args.limit)), args.seed, args.dev_fraction, args.test_fraction
    )
    n = corpus.slice_size(args.gepa_valset, len(train))
    return train[n:], train[:n], dev, test


def test_the_optimizers_valset_comes_off_train_not_out_of_dev():
    """Dev decides what ships, so it must not also be what steered the search.

    Sharing them lets a search that overfits its valset report the overfitting as a
    win, because the same rows then judge the result.
    """
    train, validation, dev, test = _default_split()
    assert (len(validation), len(dev), len(test)) == (150, 300, 150)
    assert len(train) == 2000 - 150 - 300 - 150
    assert not (set(map(id, validation)) & set(map(id, dev)))
    assert not (set(map(id, validation)) & set(map(id, train)))


def test_raising_the_limit_grows_only_the_free_slice():
    """The point of absolute sizes: valset, dev and test are paid for, train is not."""
    train, validation, dev, test = _default_split(["--limit", "4000"])
    assert (len(validation), len(dev), len(test)) == (150, 300, 150)
    assert len(train) == 4000 - 600


def test_the_reflector_sees_more_than_gepas_default_three_examples():
    """Three near-perfect examples give a reflector almost nothing to generalise from."""
    assert cli.parse_args([]).reflection_minibatch_size == 8


def test_the_program_has_one_predictor_which_is_why_merge_is_off():
    """Merge recombines across predictors; with one there is nothing to recombine.

    It copies, per predictor, whichever parent differs from the common ancestor — so
    on a single-component program every "merged" candidate is byte-identical to a
    parent, scheduled and evaluated for no new information. Pinned here because the
    reasoning stops holding the moment a second predictor appears, and the `use_merge`
    argument that depends on it is three files away.
    """
    pytest.importorskip("dspy")
    import program as program_module

    assert len(program_module.build("x").named_predictors()) == 1


def test_slice_size_reads_below_one_as_a_fraction_and_above_as_a_count():
    assert corpus.slice_size(0.25, 400) == 100
    assert corpus.slice_size(50, 400) == 50
    assert corpus.slice_size(1, 400) == 1


def test_oversized_slices_scale_down_together_instead_of_starving_dev():
    """`--source builtin` is 12 rows against defaults sized for 2000 — both slices survive.

    Satisfying test first and handing dev the remainder leaves dev empty, which reads
    as a corpus problem when it is really arithmetic.
    """
    train, dev, test = corpus.split(list(range(12)), 7, dev_size=50, test_size=150)
    assert len(dev) > 0
    assert len(dev) + len(test) <= 12
    # The 1:3 ratio the sizes asked for survives the scaling.
    assert len(test) > len(dev)
    assert len(train) == 12 - len(dev) - len(test)


def test_slices_that_already_fit_are_left_exactly_as_asked():
    """Scaling must not fire on the normal case, including dev+test == the whole corpus."""
    _, dev, test = corpus.split(list(range(500)), 7, dev_size=0.5, test_size=0.5)
    assert (len(dev), len(test)) == (250, 250)


def test_a_search_run_scores_only_the_baseline():
    """The rest re-rank instructions the search will never use, at dev-sized cost each."""
    assert cli.resolve_candidates(cli.parse_args([])) == [candidates.BASELINE]


def test_a_ranking_run_scores_everything():
    """`--optimizer none` exists to produce the ordering; one row is not an ordering."""
    assert cli.resolve_candidates(cli.parse_args(["--optimizer", "none"])) == list(
        candidates.CANDIDATES
    )


def test_seeding_from_the_best_candidate_needs_the_full_sweep():
    """ "Best" is unknowable before anything has been scored."""
    args = cli.parse_args(["--start", "best-candidate"])
    assert cli.resolve_candidates(args) == list(candidates.CANDIDATES)


def test_the_full_sweep_can_be_asked_for_explicitly():
    assert cli.resolve_candidates(cli.parse_args(["--candidates", "all"])) == list(
        candidates.CANDIDATES
    )


def test_the_task_model_has_room_for_reasoning_tokens_by_default():
    """A too-low ceiling doesn't fail the run, it poisons it.

    `PlainChatAdapter.parse` treats the whole completion as the answer, so a
    truncated completion is scored as a bad cleanup and GEPA evolves away from an
    instruction that was fine. Pinned because the symptom is a warning in the log
    and a disappointing score, not an error — 2048 was low enough that Opus 5's
    reasoning tokens tripped it mid-run.
    """
    assert cli.parse_args([]).max_tokens == 8192


def test_sampling_is_unset_by_default_and_never_reaches_the_reflection_model():
    """Current Claude models reject an explicit temperature, and the reflector is one.

    So the knob exists for the small task model's repetition loops and must not be
    applied globally to fix them.
    """
    pytest.importorskip("dspy")
    import program as program_module

    assert cli.parse_args([]).temperature is None
    spec = program_module.ModelSpec(model="openai/x", temperature=0.7)
    # dspy.LM always carries a `temperature` key; None is what makes it omitted from
    # the request, so "unset" means the value is None rather than the key being absent.
    assert spec.lm().kwargs["temperature"] is None
    assert spec.lm(temperature=spec.temperature).kwargs["temperature"] == 0.7


def test_the_reflection_model_gets_far_more_room_than_the_task_model():
    """It thinks at length before writing an instruction, and thinking is billed here.

    Separate ceilings because the models are different sizes: the default --model is a
    small stand-in on a 32k context, so it cannot be handed a frontier reflector's
    headroom, and the reflector cannot be held to the task model's.
    """
    args = cli.parse_args([])
    assert args.reflection_max_tokens == 65536
    assert args.reflection_max_tokens > args.max_tokens


def test_overage_accepts_an_explicit_cap():
    assert candidates.overage("x" * 60, cap=50) == 10
    assert candidates.overage("x" * 40, cap=50) == 0


# --------------------------------------------------------------------------
# The GEPA proposer gate — the cap as a search constraint, not just a report
# --------------------------------------------------------------------------


def _proposer_with(monkeypatch, drafts, cap=50, attempts=3):
    """A CappedInstructionProposer whose reflection step returns `drafts` in order.

    Stubbing GEPA's `InstructionProposalSignature` is what keeps this offline: the
    accept/retry decision is ours and testable, while the reflection prompt behind
    it is GEPA's and needs a paid call to exercise.
    """
    pytest.importorskip("dspy")
    import program as program_module

    seen = []

    class FakeSignature:
        @staticmethod
        def run(lm, input_dict):
            seen.append(input_dict["current_instruction_doc"])
            return {"new_instruction": drafts[len(seen) - 1]}

    monkeypatch.setattr(program_module, "InstructionProposalSignature", FakeSignature)
    proposer = program_module.CappedInstructionProposer(
        cap, attempts=attempts, fields=("raw_transcript", "cleaned_transcript")
    )
    return proposer, seen


def test_a_proposal_within_the_cap_is_accepted_first_try(monkeypatch):
    proposer, seen = _proposer_with(monkeypatch, [f"short. {SAFE}"])
    assert proposer._propose("original", []) == f"short. {SAFE}"
    assert (proposer.rejected, proposer.abandoned) == (0, 0)
    assert len(seen) == 1


def test_an_over_cap_proposal_is_rejected_and_re_asked(monkeypatch):
    proposer, seen = _proposer_with(monkeypatch, [SAFE + "z" * 80, f"fits. {SAFE}"])
    assert proposer._propose("original", []) == f"fits. {SAFE}"
    assert proposer.rejected == 1
    assert proposer.abandoned == 0
    # The retry compresses the rejected draft rather than re-deriving from the original.
    assert "z" * 80 in seen[1]
    # 30 chars of SAFE + 80 of filler against a cap of 50.
    assert "60 characters over" in seen[1]


def test_giving_up_returns_the_original_not_a_truncation(monkeypatch):
    """A truncated instruction lands mid-sentence; scoring one is how bad prompts ship."""
    proposer, _ = _proposer_with(monkeypatch, [SAFE + "z" * 80] * 3, attempts=3)
    result = proposer._propose("original", [])
    assert result == "original"
    assert len(result) != 50
    assert (proposer.rejected, proposer.abandoned) == (3, 1)


def test_a_proposal_naming_a_field_is_rejected_and_re_asked(monkeypatch):
    """The leak regenerates every run, so it is gated rather than fixed once."""
    proposer, seen = _proposer_with(
        monkeypatch, [f"{SAFE} output as cleaned_transcript", f"{SAFE} output plainly"]
    )
    assert proposer._propose("original", []) == f"{SAFE} output plainly"
    assert proposer.rejected == 1
    assert "cleaned_transcript" in seen[1]
    assert "do not exist in the message" in seen[1]


def test_a_field_naming_proposal_is_never_patched_by_hand(monkeypatch):
    """Deleting the name in-place can leave a dangling clause; return the original."""
    proposer, _ = _proposer_with(monkeypatch, [f"{SAFE} name raw_transcript here"] * 3)
    assert proposer._propose("original", []) == "original"
    assert (proposer.rejected, proposer.abandoned) == (3, 1)


def test_the_proposer_updates_every_requested_component(monkeypatch):
    proposer, _ = _proposer_with(monkeypatch, [f"one {SAFE}", f"two {SAFE}"])
    updated = proposer(
        candidate={"a": "old a", "b": "old b"},
        reflective_dataset={"a": [], "b": []},
        components_to_update=["a", "b"],
    )
    assert updated == {"a": f"one {SAFE}", "b": f"two {SAFE}"}


def test_a_perfect_score_still_says_something():
    """An empty reflection prompt is worse than an uninformative one."""
    perfect = metrics.score("identical text", "identical text")
    message = metrics.feedback("identical text", "identical text", "x", perfect)
    assert "Perfect" in message


# --------------------------------------------------------------------------
# Live verification — the wire format and the arithmetic, without a network
# --------------------------------------------------------------------------


def test_the_multipart_body_matches_what_the_swift_client_sends():
    """A framing bug here would look like a bad instruction, not a bad request."""
    import live

    body, boundary = live._multipart(b"\x01\x02", {"sample_rate": 16000})
    text = body.decode("latin-1")
    assert text.startswith(f"--{boundary}\r\n")
    assert text.endswith(f"--{boundary}--\r\n")
    assert 'name="audio"; filename="audio.pcm"' in text
    assert "Content-Type: audio/pcm\r\n\r\n" in text
    assert 'name="config"' in text
    assert '{"sample_rate": 16000}' in text
    assert b"\x01\x02" in body


def test_an_empty_instruction_asks_for_the_service_default():
    """`None` must send `llm: {}` — the wording Blurt ships, not a candidate's guess."""
    import json as _json

    import live

    for instruction, expected in ((None, {}), ("", {}), ("do x", {"instruction": "do x"})):
        body, _ = live._multipart(b"", {"llm": {"instruction": instruction} if instruction else {}})
        config = _json.loads(body.decode("latin-1").split("\r\n\r\n")[-1].split("\r\n--")[0])
        assert config["llm"] == expected


def test_the_live_summary_reports_the_gain_over_no_rewrite():
    """The floor is the verbatim transcript: what pasting without a rewrite would score."""
    import live

    results = [
        live.LiveResult(
            reference="ship it", verbatim="um ship it", rewritten="ship it", llm_error=None
        ),
        live.LiveResult(
            reference="ship it", verbatim="um ship it", rewritten="ship it", llm_error=None
        ),
    ]
    summary = live.summarize(results)
    assert summary["content"] == 1.0
    assert summary["floor_content"] < 1.0
    assert summary["gain"] > 0
    assert summary["llm_error_rate"] == 0.0


def test_a_failed_rewrite_is_counted_not_dropped():
    """The service falls back to the verbatim transcript, so that is what the user saw."""
    import live

    results = [
        live.LiveResult(
            reference="ship it", verbatim="um ship it", rewritten="um ship it", llm_error="timeout"
        ),
        live.LiveResult(
            reference="ship it", verbatim="um ship it", rewritten="ship it", llm_error=None
        ),
    ]
    assert live.summarize(results)["llm_error_rate"] == 0.5


def test_summarizing_nothing_does_not_divide_by_zero():
    import live

    assert live.summarize([])["gain"] == 0.0


def test_live_verification_is_off_unless_asked_for():
    """It costs real transcription minutes and needs a Mac — never a default."""
    assert cli.parse_args([]).verify_live == 0


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
