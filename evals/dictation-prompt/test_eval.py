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
import json
import pathlib
import re
import sys

import pytest

import candidates
import corpus
import live
import metrics
import optimize_cleanup_prompt as cli
import progress
import spoken_punctuation
from disfluency import inject

CAP = candidates.INSTRUCTION_CHARACTER_CAP

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
# False starts — the one disfluency the score charges more than one error for
# --------------------------------------------------------------------------

#: A pair carrying one abandoned phrase and one hedge, far enough apart to be separate
#: runs, so a hypothesis can leave exactly one surplus word of either kind in and the
#: two be compared directly. "we walked-" is abandoned (the cut-off says so); the "um"
#: later in the sentence is a run of its own and stays a plain leftover.
ABANDONED = ("we drove to the coast on friday", "we walked- we drove to the um coast on friday")


def test_an_abandoned_word_left_in_costs_more_than_a_hedge_left_in():
    """The whole point: one leftover word, two very different mistakes.

    Both hypotheses add exactly one token the reference does not have, so plain WER
    scores them identically — which is what left the search free to spend its
    instruction budget on filler and ignore the hard case.
    """
    reference, spoken = ABANDONED
    hedge = metrics.score(reference, "um we drove to the coast on friday", spoken)
    abandoned = metrics.score(reference, "walked we drove to the coast on friday", spoken)
    assert hedge.content_alignment.insertions == abandoned.content_alignment.insertions == 1
    assert not hedge.uncorrected_false_starts
    assert abandoned.uncorrected_false_starts == ("walked",)
    # Exactly the surcharge, over the reference's five words — the arithmetic, not
    # merely the direction, since the direction would survive any weight above 1.
    extra = (metrics.FALSE_START_WEIGHT - 1) / len(reference.split())
    assert hedge.content - abandoned.content == pytest.approx(extra)


def test_the_surcharge_reaches_both_axes():
    """Exempting formatting would dilute the weighting by 30% under the default blend."""
    reference, spoken = ABANDONED
    left_in = metrics.score(reference, "walked we drove to the coast on friday", spoken)
    removed = metrics.score(reference, reference, spoken)
    assert left_in.content < removed.content
    assert left_in.format < removed.format
    assert left_in.blend < removed.blend


def test_without_the_input_the_score_is_plain_wer():
    """Which leftovers were abandoned is a fact about what was said, not about the pair.

    So a two-argument call cannot know it, and must not guess: it scores the way the
    harness scored everything before this weighting existed.
    """
    reference, spoken = ABANDONED
    hypothesis = "walked we drove to the coast on friday"
    assert (
        metrics.score(reference, hypothesis).content
        > metrics.score(reference, hypothesis, spoken).content
    )
    assert metrics.score(reference, hypothesis).uncorrected_false_starts == ()


def test_a_clean_cleanup_is_still_perfect_with_the_input_supplied():
    """The surcharge may only punish what was left in; removing it all is still 1.0."""
    reference, spoken = ABANDONED
    assert metrics.score(reference, reference, spoken).content == 1.0
    assert metrics.score(reference, reference, spoken).uncorrected_false_starts == ()


def test_a_cut_off_word_condemns_the_whole_span_it_sits_in():
    """ "we wouldn't" is only recognizable as abandoned by the "ha-" beside it.

    Which is why the classifier works in runs: charging the fragment alone would price
    a three-word abandoned clause as a one-word slip.
    """
    tokens = metrics.false_start_tokens(
        "we wouldn't ha- we wouldn't have them", "we wouldn't have them"
    )
    assert set(tokens) == {"we", "wouldnt", "ha"}


def test_the_corpus_own_cut_off_convention_is_recognized():
    """nyra ships `th*`, which the loader rewrites to `th-` — the same signal."""
    verbatim = corpus._detag_nyra("we should go on th* Thursday")
    assert metrics.false_start_tokens(verbatim, "we should go on Thursday") == ("th",)


def test_a_repeated_phrase_is_a_stammer_not_an_abandonment():
    """The speaker said it again rather than changing course, so it is not triple-charged."""
    assert metrics.false_start_tokens("it was it was really really bad", "it was really bad") == ()


def test_hesitation_is_never_an_abandonment_however_many_words_it_runs_to():
    """Otherwise "you know" and "okay so" would be charged as abandoned phrases."""
    for spoken in (
        "um ship it on friday",
        "you know ship it on friday",
        "okay so ship it on friday",
        "ship it on, I mean, friday",
    ):
        assert metrics.false_start_tokens(spoken, "ship it on friday") == (), spoken


def test_the_injectors_palette_is_all_known_hesitation():
    """A filler the scorer does not know as one reads as an abandoned phrase.

    Two words of unrecognized hedging is exactly the shape `_is_abandoned` treats as a
    false start, so adding "at the end of the day" to the injector without telling
    `metrics.HESITATIONS` would triple the weight of its own filler.
    """
    from disfluency import FILLERS, OPENERS

    unknown = {
        word
        for phrase in (*FILLERS, *OPENERS)
        for word in metrics.normalize(phrase)
        if word not in metrics.HESITATIONS
    }
    assert unknown == set()


def test_insertion_positions_line_up_with_the_inserted_tokens():
    """The classifier indexes the spoken side with these; an off-by-one mislabels spans."""
    hypothesis = ["um", "ship", "it", "later", "on", "friday"]
    alignment = metrics.align(["ship", "it", "on", "friday"], hypothesis)
    assert len(alignment.inserted_positions) == alignment.insertions
    assert [hypothesis[i] for i in alignment.inserted_positions] == list(alignment.inserted)


# --------------------------------------------------------------------------
# Feedback — derived from the pair, not from a fixed filler list
# --------------------------------------------------------------------------


def test_feedback_names_a_leftover_word_that_came_from_the_input():
    reference, source = "Ship it on Friday.", "Um, ship it on Friday."
    hypothesis = "Um, ship it on Friday."
    note = metrics.feedback(reference, source, metrics.score(reference, hypothesis))
    assert "left disfluencies" in note
    assert "um" in note.lower()


def test_feedback_distinguishes_invented_words_from_leftover_ones():
    """A word in neither the input nor the target is a hallucination, not a leftover."""
    reference, source = "Ship it on Friday.", "Ship it on Friday."
    hypothesis = "Ship it on Friday urgently."
    note = metrics.feedback(reference, source, metrics.score(reference, hypothesis))
    assert "added words that were not in the transcript" in note
    assert "left disfluencies" not in note


def test_feedback_works_for_disfluencies_no_filler_list_would_contain():
    """The corpus decides what a disfluency is — real transcripts aren't enumerable."""
    reference = "We should go on Thursday."
    source = "We should uhh go on go on Thursday."
    hypothesis = "We should uhh go on Thursday."
    note = metrics.feedback(reference, source, metrics.score(reference, hypothesis))
    assert "uhh" in note


def test_feedback_names_an_abandoned_span_apart_from_ordinary_leftovers():
    """A reflector shown one undifferentiated list cannot tell which words cost triple."""
    reference, spoken = ABANDONED
    note = metrics.feedback(
        reference,
        spoken,
        metrics.score(reference, "walked we drove to the um coast on friday", spoken),
    )
    assert "abandoned false start" in note
    assert "walked" in note.split("left disfluencies")[0]
    # The hedge is still reported, and still reported as the cheaper mistake.
    assert "left disfluencies in the output: um" in note


def test_feedback_names_dropped_content():
    reference, source = "Ship the revised build on Friday.", "Ship the revised build on Friday."
    hypothesis = "Ship on Friday."
    note = metrics.feedback(reference, source, metrics.score(reference, hypothesis))
    assert "dropped content words" in note


def test_feedback_on_a_perfect_cleanup_is_not_empty():
    note = metrics.feedback(SENTENCE, SENTENCE, metrics.score(SENTENCE, SENTENCE))
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


def test_the_no_cleanup_floor_is_charged_the_surcharge_like_everything_else():
    """The floor is a candidate that deleted nothing, so it keeps every false start.

    It has to be measured on the same objective the candidates are, or "how much work
    is there to do" is answering a different question than the score does.
    """
    rows = list(corpus.load(source="builtin", limit=12, seed=6, severity=0.5).utterances)
    unweighted = metrics.mean([metrics.score(u.reference, u.disfluent) for u in rows])
    assert corpus.no_cleanup_floor(rows)["content"] < unweighted["content"]


def test_the_utterance_carries_both_sides_into_the_score():
    """The helper exists so no call site has to remember the input; check it passes it."""
    reference, spoken = ABANDONED
    utterance = corpus.Utterance(reference=reference, disfluent=spoken)
    hypothesis = "walked we drove to the coast on friday"
    assert utterance.scored(hypothesis) == metrics.score(reference, hypothesis, spoken)
    assert utterance.scored(hypothesis).uncorrected_false_starts == ("walked",)


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
    # answer/translate are covered by `missing_safeguards` (by stem, so they survive
    # rephrasing); "rephrase" is deliberately not in REQUIRED_SAFEGUARDS, so it is the
    # one this has to assert itself.
    assert candidates.missing_safeguards(candidates.PRIOR_WINNER) == []
    assert "rephrase" in candidates.PRIOR_WINNER


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
    note = metrics.feedback(ref, "Um, ship it on Friday.", metrics.score(ref, hyp), "content")
    assert "(content)" in note
    assert "formatting score" not in note


def test_a_case_only_difference_is_perfect_on_the_content_axis():
    """And must read that way, rather than nagging about an artifact of the targets.

    Where a corpus builds its clean side by stripping markup mechanically, a formatting
    complaint is the harness pointing at its own corpus damage.
    """
    ref, hyp = "Ship it on Friday.", "ship it on friday"
    assert metrics.score(ref, hyp).content == 1.0
    assert "Perfect" in metrics.feedback(ref, ref, metrics.score(ref, hyp), axis="content")


def test_the_feedback_does_not_repeat_what_gepa_already_shows():
    """ "Generated Outputs" carries the produced text; the reference is what is missing."""
    scored = metrics.score("ship it", "um ship it")
    note = metrics.feedback("ship it", "um ship it", scored)
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
    assert [n.code for n in notes] == ["length"]
    assert f"{cap + 250} characters" in notes[0].message
    assert "250 characters over" in notes[0].message
    # Stated in words as well: a reflector told "cut 638 characters" came back longer,
    # so the number it is asked to act on has to be in a unit it can count.
    assert f"{candidates.word_budget(cap)}-word target" in notes[0].message
    assert f"at least {candidates.in_words(250)} words" in notes[0].message


def test_naming_a_signature_field_is_an_objection():
    """The fields are in neither envelope, and the label can reach the user's document."""
    notes = candidates.objections(
        f"{SAFE} Output the result as `cleaned_transcript`.",
        fields=("raw_transcript", "cleaned_transcript"),
    )
    assert [n.code for n in notes] == ["fields"]
    assert "cleaned_transcript" in notes[0].message
    # Only the field it actually named, so the re-ask isn't chasing a phantom.
    assert "raw_transcript" not in notes[0].message


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
    assert [n.code for n in notes] == ["length", "fields"]


def test_dropping_a_safeguard_is_an_objection():
    """The corpus cannot punish this and the length pressure rewards it — so gate it.

    Every corpus here is conversational English between two humans, so an instruction
    that stops forbidding "answer the text" scores exactly the same while freeing ~90
    characters under a cap the reflector is told to cut toward. Deleting it is what a
    well-behaved optimizer *should* do given what it can see.
    """
    notes = candidates.objections("Delete the disfluencies and nothing else.", fields=())
    assert [n.code for n in notes] == ["safeguard"]


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
    preamble = candidates.constraint_preamble(seed, cap=CAP)
    assert seed in preamble
    assert candidates.CONSTRAINT_MARKER in preamble
    # The headroom, not just the ceiling, and in words — a reflector told "at most 2048
    # characters" cannot check its own work, and one told to cut 638 came back longer.
    budget = candidates.word_budget(CAP)
    # Bracketed: first line and last line, because the ask is weakly obeyed and a
    # constraint stated once in the middle of a long prompt is a constraint lost.
    assert preamble.startswith("BEFORE YOU BEGIN")
    assert f"aim for {budget} WORDS" in preamble
    assert preamble.rstrip().endswith(f"Hard maximum {candidates.hard_word_limit(CAP)} words.")
    assert preamble.count(str(budget)) >= 3
    assert f"{len(seed.split())} words" in preamble
    # A target AND a ceiling, so the overshoot has somewhere to land that still fits.
    assert candidates.word_budget(CAP) < candidates.hard_word_limit(CAP)
    # Restated structurally, because a model cannot count its own words while writing.
    assert f"{candidates.sentence_budget(CAP)} sentences" in preamble
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
    assert [n.code for n in notes] == ["scaffolding"]


def test_the_first_attempt_is_asked_with_the_constraints_attached(monkeypatch):
    """The regression itself: attempt one must already know the budget."""
    proposer, seen = _proposer_with(monkeypatch, [f"short. {SAFE}"])
    proposer._propose("the current instruction", [])
    assert candidates.CONSTRAINT_MARKER in seen[0]
    assert "the current instruction" in seen[0]


def test_the_revision_directive_carries_the_draft_and_every_objection():
    notes = [candidates.Objection("a", "first problem"), candidates.Objection("b", "second")]
    directive = candidates.revision_directive("the draft", notes)
    assert "the draft" in directive
    assert "- first problem" in directive
    assert "- second" in directive
    # The block the gate matches on, not a second spelling of it that could drift.
    assert candidates.CONSTRAINT_MARKER in directive


def test_the_shipped_winner_names_no_signature_field():
    """The gate is for new proposals; this is the one already in the table."""
    pytest.importorskip("dspy")
    import program as program_module

    for field in (program_module.INPUT_FIELD, program_module.OUTPUT_FIELD):
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


def test_help_renders(capsys):
    """`--help` was broken from the day a help string first said "~42%".

    argparse %-expands help text against a dict of params, so a bare `%` raises
    TypeError and the whole thing fails — silently invisible to every test, because
    nothing here had ever asked for the help.
    """
    with pytest.raises(SystemExit) as raised:
        cli.parse_args(["--help"])
    assert raised.value.code == 0
    printed = capsys.readouterr().out
    assert "--spoken-punctuation" in printed
    assert "--dump-corpus" in printed


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
    validation, train = corpus.carve_validation(train, args.gepa_valset)
    return train, validation, dev, test


def test_the_optimizers_valset_comes_off_train_not_out_of_dev():
    """Dev decides what ships, so it must not also be what steered the search.

    Sharing them lets a search that overfits its valset report the overfitting as a
    win, because the same rows then judge the result.
    """
    train, validation, dev, test = _default_split()
    assert (len(validation), len(dev), len(test)) == (450, 900, 450)
    assert len(train) == 4000 - 450 - 900 - 450
    assert not (set(map(id, validation)) & set(map(id, dev)))
    assert not (set(map(id, validation)) & set(map(id, train)))


def test_raising_the_limit_grows_only_the_free_slice():
    """The point of absolute sizes: valset, dev and test are paid for, train is not."""
    train, validation, dev, test = _default_split(["--limit", "6000"])
    assert (len(validation), len(dev), len(test)) == (450, 900, 450)
    assert len(train) == 6000 - 1800


def test_the_paid_slices_are_sized_for_a_verdict_that_can_be_trusted():
    """A --auto heavy search once landed 0.001 behind its seed on 300 dev rows.

    That is not a result, it is a coin flip that cost 27 reflection trials, and more
    trials only sample the same noise again — noise falls with the square root of rows,
    so only the rows fix it. Tripled together: dev decides what ships, the valset
    decides what the search chases, and a winner is worth nothing if either is guessing.
    """
    args = cli.parse_args([])
    assert (args.dev_fraction, args.gepa_valset, args.test_fraction) == (900, 450, 450)
    # Still inside the corpus: nyra's train split is 4458 rows before filtering.
    assert args.limit == 4000
    assert args.dev_fraction + args.gepa_valset + args.test_fraction < args.limit


def test_the_hard_disfluency_outweighs_the_easy_one_by_a_measured_margin():
    """Not a round number someone liked: 5 is where the metric holds the most resolution.

    Higher keeps sharpening the gradient between a good cleanup and a nearly-good one,
    but pushes wholly-failed rows into `from_error_rate`'s flattening tail, where they
    stop being rankable against each other. See the sweep in the constant's own docs.
    """
    assert metrics.FALSE_START_WEIGHT == 5.0


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
    # No `fields=`: the constructor defaults to (INPUT_FIELD, OUTPUT_FIELD), so these
    # tests gate on the same names a real run does. Spelling them here again would keep
    # passing — while gating nothing — the day the signature's fields are renamed.
    proposer = program_module.CappedInstructionProposer(cap, attempts=attempts)
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
    message = metrics.feedback("identical text", "x", perfect)
    assert "Perfect" in message


# --------------------------------------------------------------------------
# Live verification — the wire format and the arithmetic, without a network
# --------------------------------------------------------------------------


def test_the_multipart_body_matches_what_the_swift_client_sends():
    """A framing bug here would look like a bad instruction, not a bad request."""

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

    for instruction, expected in ((None, {}), ("", {}), ("do x", {"instruction": "do x"})):
        body, _ = live._multipart(b"", {"llm": {"instruction": instruction} if instruction else {}})
        config = json.loads(body.decode("latin-1").split("\r\n\r\n")[-1].split("\r\n--")[0])
        assert config["llm"] == expected


def test_the_live_summary_reports_the_gain_over_no_rewrite():
    """The floor is the verbatim transcript: what pasting without a rewrite would score."""

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


# --------------------------------------------------------------------------
# Spoken punctuation
# --------------------------------------------------------------------------

# One pair in the shape `nyra` supplies: both sides punctuated, the disfluent side
# carrying a comma (`really,`) the reference does not, and a proper noun sitting
# where a sentence starts.
SPOKEN_REFERENCE = "We shipped it today. Monday was quiet, so nobody noticed."
SPOKEN_DISFLUENT = "Um we shipped it today. Monday was really, quiet, so nobody noticed."


def spoken_pair(**kwargs):
    """`(reference, input, commands)` for the pair above."""
    return spoken_punctuation.inject(SPOKEN_REFERENCE, SPOKEN_DISFLUENT, **kwargs)


# A pair whose one convertible mark is internal, so exactly one command is planted and the
# spoken side doubles as the "left the command in" hypothesis. Single-sentence fixtures no
# longer work here: `inject` will not speak an utterance-final mark, because that is the
# one mark any instruction produces unprompted.
ONE_COMMAND_TEXT = "Is it ready? Let me know either way."


def one_command(text: str = ONE_COMMAND_TEXT):
    """`(reference, spoken input, the single command)`."""
    reference, spoken, commands = spoken_punctuation.inject(
        text, text, seed=1, rate=1.0, caps_rate=0.0
    )
    (command,) = commands
    return reference, spoken, command


def test_a_perfect_cleanup_is_still_the_reference_exactly():
    """The invariant the whole module rests on: the planted task is achievable.

    Marks are spoken only where the reference licenses them, so the correct answer never
    stops being the corpus's own target. If this fails, some row is asking for a mark its
    target does not contain and no instruction can score 1.0 on it.
    """
    reference, disfluent, commands = spoken_pair(seed=3, rate=1.0, caps_rate=1.0)
    assert commands
    scored = metrics.score(reference, reference, disfluent)
    assert (scored.content, scored.format) == (1.0, 1.0)
    assert spoken_punctuation.tally([(commands, reference)])["commands_converted"] == 1.0


def test_leaving_every_command_in_is_scored_as_leaving_every_command_in():
    reference, disfluent, commands = spoken_pair(seed=3, rate=1.0, caps_rate=1.0)
    assert spoken_punctuation.tally([(commands, disfluent)])["commands_literal"] == 1.0


def test_spoken_injection_is_deterministic_for_a_seed():
    assert spoken_pair(seed=5) == spoken_pair(seed=5)


def test_rate_zero_plants_nothing_and_leaves_both_sides_alone():
    reference, disfluent, commands = spoken_pair(seed=5, rate=0.0, caps_rate=0.0)
    assert (reference, disfluent, commands) == (SPOKEN_REFERENCE, SPOKEN_DISFLUENT, ())


def test_rates_out_of_range_are_rejected():
    with pytest.raises(ValueError):
        spoken_pair(seed=1, rate=1.5)
    with pytest.raises(ValueError):
        spoken_pair(seed=1, caps_rate=-0.1)


def test_only_marks_the_reference_licenses_are_ever_spoken():
    """A mark the target lacks would ask for punctuation and then score it as an error.

    `really,` is in the input and not in the reference, which is ordinary for `nyra` —
    the annotator deleted the span it introduced. Speaking it would teach an instruction
    that commands are sometimes to be ignored.
    """
    assert ("really", ",") not in spoken_punctuation.licensed_marks(SPOKEN_REFERENCE)
    _, disfluent, _ = spoken_pair(seed=5, rate=1.0, caps_rate=0.0)
    assert "really," in disfluent


def test_a_spoken_terminal_mark_takes_its_sentence_capital_with_it():
    """Otherwise the casing alone restores the period and the eval measures nothing."""
    reference, disfluent, commands = spoken_punctuation.inject(
        "We shipped it today. Nobody noticed.",
        "We shipped it today. Nobody noticed.",
        seed=2,
        rate=1.0,
        caps_rate=0.0,
    )
    assert "today period nobody" in disfluent
    assert reference == "We shipped it today. Nobody noticed."
    # One command, not two: the second period ends the utterance and is left alone.
    assert [c.mark for c in commands] == ["."]
    assert disfluent.endswith("noticed.")


def test_a_name_after_a_spoken_mark_is_lowercased_like_any_other_word():
    """It is sentence-initial in the reference, so restoring its capital *is* the task.

    A corpus-derived proper-noun rule stood here first, on the theory that lowercasing
    `Monday` charges a correct cleanup for the injector's damage. It does not: the
    required output is `Monday` and the required action is "capitalize the first word
    after a sentence-ending mark", which is the same for a name and an ordinary word. What
    the rule did do was hand the answer to 30% of the commands on `nyra` — the share whose
    following word appears capitalized mid-sentence somewhere in the corpus.
    """
    _, disfluent, _ = spoken_pair(seed=5, rate=1.0, caps_rate=0.0)
    assert "monday" in disfluent.split()
    assert "Monday" not in disfluent
    # And the target still asks for the capital, so nothing about the task got easier.
    assert "today. Monday" in SPOKEN_REFERENCE


def test_the_pronoun_i_is_the_one_capital_that_survives():
    """It is capitalized everywhere, mid-sentence included, so lowercasing it is unlike
    every other case.

    `politics full stop i'm not sure` is a transcript no speech-to-text service returns,
    and it would show the model the same token cased two ways in one utterance.
    """
    text = "I like politics. I'm not sure why."
    _, disfluent, _ = spoken_punctuation.inject(text, text, seed=1, rate=1.0, caps_rate=0.0)
    assert "I'm" in disfluent
    assert "i'm" not in disfluent


def test_all_caps_is_the_only_operator_that_edits_the_reference():
    """And it has to: a target with no uppercase in it cannot pose the task."""
    reference, _, _ = spoken_pair(seed=5, rate=1.0, caps_rate=0.0)
    assert reference == SPOKEN_REFERENCE
    shouted, disfluent, commands = spoken_pair(seed=5, rate=0.0, caps_rate=1.0)
    caps = [c for c in commands if c.kind == "caps"]
    assert caps
    assert shouted != SPOKEN_REFERENCE
    assert any(word.strip(metrics.PUNCTUATION).isupper() for word in shouted.split())
    # The input carries the command plus the plain lowercase word, so nothing in it
    # leaks the answer.
    assert caps[0].spoken in disfluent
    for word in caps[0].words:
        assert word in metrics.normalize(disfluent)
        assert word.upper() not in disfluent.split()


def test_a_caps_run_carries_no_punctuation_so_the_two_operators_cannot_collide():
    """`caps off` goes after the run's last word; a run ending in `today.` would strand it."""
    for seed in range(40):
        _, _, commands = spoken_pair(seed=seed, rate=1.0, caps_rate=1.0)
        for command in (c for c in commands if c.kind == "caps"):
            assert all(word == metrics.normalize_text(word) for word in command.words)


def test_a_caps_command_is_invisible_to_the_content_axis_and_visible_to_format():
    """Which is why `--spoken-punctuation` selects on format."""
    shouted, disfluent, commands = spoken_pair(seed=5, rate=0.0, caps_rate=1.0)
    assert [c.kind for c in commands] == ["caps"]
    # A cleanup that did everything but the shouting.
    unshouted = " ".join(
        word.lower() if word.strip(metrics.PUNCTUATION).isupper() else word
        for word in shouted.split()
    )
    scored = metrics.score(shouted, unshouted, disfluent)
    assert scored.content == 1.0
    assert scored.format < 1.0
    assert spoken_punctuation.outcome(commands[0], unshouted) == "missing"


def test_a_two_word_command_is_not_charged_as_an_abandoned_false_start():
    """Without the exemption a leftover "question mark" costs ten errors and "period" one.

    `_is_abandoned`'s rule 2 is "two or more non-hesitation words that echo nothing",
    which is exactly the shape of a dictation command. The asymmetry it produces is one
    nobody chose, and it would push the search at the multi-word commands for arithmetic
    reasons.
    """
    reference = "Is it ready?"
    disfluent = "is it ready question mark"
    exempt = frozenset({"question", "mark"})
    assert metrics.false_start_tokens(disfluent, reference) == ("question", "mark")
    assert metrics.false_start_tokens(disfluent, reference, exempt) == ()
    charged = metrics.score(reference, disfluent, disfluent)
    exempted = metrics.score(reference, disfluent, disfluent, exempt)
    assert exempted.content > charged.content


def test_a_leftover_command_word_costs_its_own_weight():
    """Not one, and not the incidental two it used to cost.

    Plain WER already charged a leftover command twice on the format axis — a
    substitution for the mark that never appeared plus an insertion for the word that
    did — so it came to 2 without anyone deciding 2.
    """
    # Long enough that the charge stays inside WER 1, where `1 - WER` is linear and the
    # error count can be read back off the score. Past that `from_error_rate` decays.
    reference, spoken, command = one_command()
    words = frozenset(command.spoken_words)
    left_in = metrics.score(reference, spoken, spoken, words)
    charged = (1.0 - left_in.content) * left_in.content_alignment.reference_length
    assert charged == pytest.approx(metrics.COMMAND_WEIGHT * len(command.spoken_words))
    assert left_in.uncorrected_commands == ("mark", "question")


def test_leaving_a_command_in_is_clearly_worse_than_dropping_it():
    """The distinction the old incidental 2 could barely make.

    `Is it ready` for `Is it ready?` is a missing mark. `Is it ready question mark` puts
    two words in the reader's document that the speaker never meant to write.
    """
    reference, spoken, command = one_command()
    words = frozenset(command.spoken_words)
    dropped = metrics.score(reference, spoken_punctuation.undo(command, reference), spoken, words)
    left_in = metrics.score(reference, spoken, spoken, words)
    assert left_in.format < dropped.format
    lost = dropped.format - left_in.format
    assert lost > (1.0 - dropped.format), "leaving it in must cost more than the mark alone"


def test_a_command_word_is_charged_once_even_inside_an_abandoned_span():
    """Rule 1 of `_is_abandoned` fires on a cut-off word whatever the vocabulary, so a
    command caught in that run would otherwise be charged at both weights."""
    reference = "We would have them."
    disfluent = "we wouldn't ha- period we would have them"
    words = frozenset({"period"})
    scored = metrics.score(reference, disfluent, disfluent, words)
    charged_as_abandoned = set(scored.uncorrected_false_starts)
    assert "period" in charged_as_abandoned
    assert "period" not in scored.uncorrected_commands


def test_a_command_costs_less_than_an_abandoned_word_and_more_than_a_filler():
    """The ordering the two weights exist to express.

    An abandoned span fabricates a clause the speaker never said; a command is one stray
    word that failed to disappear; a filler reads as a typo.
    """
    assert 1.0 < metrics.COMMAND_WEIGHT < metrics.FALSE_START_WEIGHT


def test_the_command_weight_is_neutral_on_a_corpus_that_plants_nothing():
    reference = "We would have them."
    disfluent = "we wouldn't ha- we would have them"
    assert metrics.score(reference, disfluent, disfluent) == metrics.score(
        reference, disfluent, disfluent, frozenset()
    )


def test_feedback_names_a_leftover_command_apart_from_a_disfluency_and_says_what_it_cost():
    """Calling "comma" a disfluency points the reflector at the wrong rule: it is not a
    hesitation the speaker made, it is an instruction they gave."""
    reference, spoken, command = one_command()
    words = frozenset(command.spoken_words)
    scored = metrics.score(reference, "Um " + spoken, "um " + spoken, words)
    text = metrics.feedback(reference, "um " + spoken, scored)
    assert "dictated punctuation commands" in text
    assert f"{metrics.COMMAND_WEIGHT:g} errors" in text
    # The filler was in the input, so it is a leftover — reported, and separately.
    assert "left disfluencies in the output: um" in text


def test_the_note_and_the_feedback_do_not_both_report_a_leftover_command():
    """Said in both places it was the same complaint twice in every reflection prompt.

    `metrics.feedback` owns it, because that is where the weight lives and a failure named
    without its cost is half a fact. The note owns what metrics cannot see: a command
    whose words are gone and whose mark never appeared.
    """
    reference, spoken, command = one_command()
    assert spoken_punctuation.feedback_note((command,), spoken) == ""
    # Dropped, on the other hand, is invisible to metrics on the content axis.
    dropped = spoken_punctuation.feedback_note(
        (command,), spoken_punctuation.undo(command, reference)
    )
    assert "did not carry out" in dropped


def test_the_exemption_is_neutral_on_a_corpus_that_plants_nothing():
    """Every number measured before it existed has to still hold."""
    reference = "We would have them."
    disfluent = "we wouldn't ha- we would have them"
    assert metrics.score(reference, disfluent, disfluent) == metrics.score(
        reference, disfluent, disfluent, frozenset()
    )


def test_the_utterance_hands_its_own_planted_commands_to_the_scorer():
    """`Utterance.scored` is the one place that knows both sides and what was planted."""
    reference, spoken, command = one_command()
    utterance = corpus.Utterance(reference=reference, disfluent=spoken, commands=(command,))
    assert utterance.command_words == frozenset({"question", "mark"})
    assert utterance.scored(spoken) == metrics.score(
        reference, spoken, spoken, utterance.command_words
    )


def test_the_reported_false_start_fraction_is_the_charged_one():
    """The figure printed and the figure charged came from different code paths once."""
    reference, disfluent, commands = spoken_punctuation.inject(
        "Is it ready?", "is it ready?", seed=1, rate=1.0, caps_rate=0.0
    )
    utterances = [corpus.Utterance(reference=reference, disfluent=disfluent, commands=commands)]
    assert corpus.false_start_fraction(utterances) == 0.0


def test_a_command_left_in_is_told_apart_from_a_command_dropped():
    reference, spoken, command = one_command()
    assert spoken_punctuation.outcome(command, reference) == "converted"
    assert spoken_punctuation.outcome(command, spoken) == "literal"
    assert (
        spoken_punctuation.outcome(command, spoken_punctuation.undo(command, reference))
        == "missing"
    )


def test_conversion_is_credited_on_the_anchor_not_on_any_mark_anywhere():
    """Otherwise punctuating something else entirely reads as obeying the command."""
    _, _, command = one_command()
    assert spoken_punctuation.outcome(command, "Is it? ready let me know either way") == "missing"


def test_the_literal_match_is_anchored_so_an_ordinary_word_is_not_charged():
    """ "the Cretaceous period was long" is content, not a command left in."""
    reference, _, command = one_command("It ended then. We moved on to the next thing.")
    assert command.anchor == "then"
    assert (
        spoken_punctuation.outcome(command, "The Cretaceous period was long. " + reference)
        == "converted"
    )


def test_a_shouted_run_is_found_as_a_run_not_word_by_word():
    """A word-keyed lookup found the wrong copy and marked a correct answer missed.

    On "All the people signed confessions ... trying THESE PEOPLE now" it took the first
    "people" — lowercase, eight words earlier — and reported the run as not shouted.
    """
    command = spoken_punctuation.Command(
        spoken="caps on", mark="", kind="caps", words=("these", "people")
    )
    hypothesis = "All the people signed confessions. They been trying THESE PEOPLE now."
    assert spoken_punctuation.outcome(command, hypothesis) == "converted"
    assert (
        spoken_punctuation.outcome(command, "All the people signed. Trying these people now.")
        == "missing"
    )


def test_every_planted_command_is_answered_by_its_own_reference():
    """The corpus-wide version of the achievability invariant, over enough rows to bite.

    A one-row check passes on a construction that is wrong on some shape appearing once
    in four hundred — which is how the run-as-a-run bug above got in.
    """
    reference = "All the people signed confessions, they went to a trial by jury."
    disfluent = "All the people signed confessions, they went to a trial by jury."
    for seed in range(60):
        target, spoken_side, commands = spoken_punctuation.inject(
            reference, disfluent, seed=seed, rate=1.0, caps_rate=1.0
        )
        assert metrics.score(target, target, spoken_side).format == 1.0
        for command in commands:
            assert spoken_punctuation.outcome(command, target) == "converted", command


def test_the_tally_of_nothing_says_nothing_rather_than_zero_percent():
    assert spoken_punctuation.tally([])["commands_total"] == 0.0
    assert spoken_punctuation.tally([((), "anything")])["commands_converted"] == 0.0


def test_the_literal_use_fraction_matches_phrases_not_their_words():
    """Matching words reported a fifth of `nyra` as traps; it was the words "all" and "on".

    A diagnostic that overstates the blind spot by 10x is worse than none, because it
    argues the gap has already been closed.
    """
    assert spoken_punctuation.literal_use_fraction(["The Cretaceous period was long."]) == 1.0
    assert (
        spoken_punctuation.literal_use_fraction(["We looked at all of it and turned it on."]) == 0.0
    )
    assert spoken_punctuation.literal_use_fraction([]) == 0.0


def test_the_command_vocabulary_covers_the_marks_the_task_is_named_for():
    """period, comma, question mark, ALL CAPS — plus the aliases people actually say."""
    assert {".", ",", "?"} <= set(spoken_punctuation.SPOKEN_FORMS)
    assert "full stop" in {form for form, _ in spoken_punctuation.SPOKEN_FORMS["."]}
    assert spoken_punctuation.CAPS_WORD == "all caps"


def test_spoken_punctuation_layers_onto_the_real_disfluencies_rather_than_replacing_them():
    """The task under test is saying "comma" *while* hesitating, not either alone."""
    loaded = corpus.load(source="builtin", limit=12, spoken_punctuation_rate=1.0)
    operations = {op for u in loaded.utterances for op in u.operations}
    assert any(op.startswith("spoken:") for op in operations)
    assert any(not op.startswith("spoken:") for op in operations)
    assert loaded.detail["spoken_punctuation_rate"] == 1.0


def test_a_corpus_without_the_flag_plants_nothing():
    loaded = corpus.load(source="builtin", limit=12)
    assert all(u.commands == () for u in loaded.utterances)
    assert all(u.command_words == frozenset() for u in loaded.utterances)


# The committed dataset, and the exact arguments that produce it. Both live here rather
# than only in `data/README.md` so the file is self-verifying: a change to either injector
# fails this suite instead of quietly invalidating a dataset still sitting in the tree.
FROZEN_DATASET = pathlib.Path(__file__).parent / "data" / "spoken-punctuation.jsonl"
FROZEN_ARGV = (
    "--source punctuation --punctuation-only --limit 200 --spoken-caps-rate 0.35 --seed 7"
).split()


def frozen_corpus():
    return corpus.load(
        source="punctuation",
        limit=200,
        spoken_punctuation_rate=1.0,
        spoken_caps_rate=0.35,
        punctuation_only=True,
        seed=7,
    )


def test_the_committed_dataset_is_what_the_generator_still_produces(tmp_path):
    """A frozen dataset nobody re-derives is a dataset that silently goes stale.

    The alternative is a file in the tree that was correct when it was written and is now
    a different corpus from the one the code builds — and every number measured on it
    unattributable to either. Regenerate it with the command in `data/README.md`.
    """
    regenerated = tmp_path / "spoken-punctuation.jsonl"
    corpus.dump_jsonl(frozen_corpus(), str(regenerated))
    assert regenerated.read_text(encoding="utf-8") == FROZEN_DATASET.read_text(encoding="utf-8")


def test_the_frozen_dataset_round_trips_through_the_loader():
    """Reading it back has to reproduce the corpus, commands included.

    Scoring a dumped dataset is only scoring the corpus it came from if the commands
    survive: without them the tally reports nothing and the false-start classifier goes
    back to charging "question mark" as an abandoned phrase.
    """
    generated = frozen_corpus()
    reloaded = corpus.load(jsonl=str(FROZEN_DATASET), limit=200)
    assert len(reloaded) == len(generated)
    for a, b in zip(generated.utterances, reloaded.utterances, strict=True):
        assert (a.reference, a.disfluent) == (b.reference, b.disfluent)
        assert a.commands == b.commands
        assert a.command_words == b.command_words
        assert a.scored(a.reference) == b.scored(b.reference)


def test_a_reloaded_dataset_is_not_injected_over_again():
    """The flag is often still on the command line; injecting twice would speak marks that
    are no longer there and uppercase an ALL CAPS run a second time."""
    reloaded = corpus.load(jsonl=str(FROZEN_DATASET), limit=200, spoken_punctuation_rate=1.0)
    generated = frozen_corpus()
    assert [u.disfluent for u in reloaded.utterances] == [u.disfluent for u in generated.utterances]


def test_a_dumped_row_whose_input_matches_its_reference_is_still_left_alone(tmp_path):
    """The case `is_disfluent` got wrong, and the reason `input_supplied` is recorded.

    A row where no command and no disfluency were drawn reads as "needs injecting", so
    reloading would hand it a different input than the file records — a dumped corpus that
    is not the corpus it was dumped from, with nothing to say so.
    """
    path = tmp_path / "clean.jsonl"
    text = "The build failed because the certificate expired over the weekend."
    path.write_text(json.dumps({"reference": text, "disfluent": text}) + "\n", encoding="utf-8")
    (utterance,) = corpus.load(jsonl=str(path), limit=1).utterances
    assert utterance.disfluent == text


def test_a_jsonl_row_with_only_a_reference_still_goes_through_the_injector(tmp_path):
    path = tmp_path / "bare.jsonl"
    text = "The build failed because the certificate expired over the weekend."
    path.write_text(json.dumps({"reference": text}) + "\n", encoding="utf-8")
    (utterance,) = corpus.load(jsonl=str(path), limit=1).utterances
    assert utterance.disfluent != text
    assert utterance.operations


def test_the_frozen_dataset_can_charge_over_conversion_where_nyra_cannot():
    """Its whole reason for existing beyond being a fixture.

    `nyra` uses a command word as content on ~0-1% of rows, so nothing there punishes an
    instruction that rewrites "the Jurassic period was long" into "the Jurassic. was
    long". These sentences were written to.
    """
    assert spoken_punctuation.literal_use_fraction(corpus.PUNCTUATION_SAMPLE) > 0.1
    assert spoken_punctuation.literal_use_fraction(corpus.BUILTIN_SAMPLE) > 0.1


def test_the_dump_flag_works_without_a_key_or_a_network(tmp_path):
    """Generating a dataset must not require paying for a run."""
    path = tmp_path / "dump.jsonl"
    assert (
        cli.main([*FROZEN_ARGV, "--dump-corpus", str(path), "--dry-run", "--show-samples", "0"])
        == 0
    )
    assert path.read_text(encoding="utf-8") == FROZEN_DATASET.read_text(encoding="utf-8")


def test_the_original_offline_sample_is_still_the_first_twelve_rows():
    """`--limit 12` and the tests that use it have to see what they always saw."""
    assert len(corpus.BUILTIN_SAMPLE) > 12
    assert corpus.BUILTIN_SAMPLE[0].startswith("The build failed because the signing")
    assert corpus.BUILTIN_SAMPLE[11].endswith("menu bar item at all.")


def test_every_bundled_sentence_survives_the_injection_filter():
    """A fixture that silently drops the rows it was written to contain is a bad fixture."""
    kept = {u.reference for u in corpus.load(source="builtin", limit=500).utterances}
    assert len(kept) == len(corpus.BUILTIN_SAMPLE)


def test_the_bundled_sample_exercises_the_capital_after_a_spoken_mark():
    """It did not, for 0 of 61 terminal marks: every sentence ended at its own period, so
    there was no following word whose capital a period command has to restore.

    That is half of what a terminal command asks for, and on `nyra` — where utterances run
    to several sentences — it is 26% of terminal marks.
    """
    eligible = terminal = 0
    for utterance in corpus.load(source="builtin", limit=500).utterances:
        toks = utterance.reference.split()
        for i, raw in enumerate(toks):
            if raw and raw[-1] in spoken_punctuation.TERMINAL_MARKS:
                if not spoken_punctuation._split_mark(raw):
                    continue
                terminal += 1
                if i + 1 < len(toks) and not spoken_punctuation._keeps_its_capital(toks[i + 1]):
                    eligible += 1
    assert eligible >= 10, f"only {eligible} of {terminal} terminal marks have a next word"


def test_the_bundled_sample_exercises_every_mark_in_the_vocabulary():
    """`nyra` supplies no exclamation point, colon or semicolon at all, so if these
    entries in SPOKEN_FORMS are to mean anything, this corpus has to license them."""
    licensed = set()
    for text in corpus.BUILTIN_SAMPLE:
        licensed |= {mark for _, mark in spoken_punctuation.licensed_marks(text)}
    assert set(spoken_punctuation.SPOKEN_FORMS) <= licensed


def test_an_utterance_final_mark_is_never_spoken():
    """It is the one command that tests nothing.

    A dictated "period" on the last word asks for a mark any instruction would produce
    unprompted, so obeying it and ignoring it score the same. Those were 55% of what the
    bundled corpus licensed.
    """
    text = "We shipped it today. Nobody noticed."
    _, spoken, commands = spoken_punctuation.inject(text, text, seed=1, rate=1.0, caps_rate=0.0)
    assert spoken.endswith("noticed.")
    assert len(commands) == 1


def test_a_row_whose_only_mark_is_final_yields_no_command_at_all():
    """Which is why `--punctuation-only` drops such rows rather than keeping them."""
    text = "The build failed over the weekend and nobody noticed."
    _, spoken, commands = spoken_punctuation.inject(
        text, text, seed=1, rate=1.0, caps_rate=0.0, require=True
    )
    assert commands == ()
    assert spoken == text


def test_require_guarantees_a_command_wherever_one_is_possible():
    """A row carrying none is not a hard example on this task; it measures nothing."""
    text = "We shipped it today. Monday was quiet, so nobody noticed."
    without = sum(
        not spoken_punctuation.inject(text, text, seed=n, rate=0.15, caps_rate=0.0)[2]
        for n in range(200)
    )
    with_require = sum(
        not spoken_punctuation.inject(text, text, seed=n, rate=0.15, caps_rate=0.0, require=True)[2]
        for n in range(200)
    )
    assert without > 50
    assert with_require == 0


def test_every_planted_command_changes_something():
    """The invariant that makes the corpus worth scoring at all.

    A command worth 0 is decoration — the same output scores the same whether the model
    understood it or not. Mid-utterance terminal marks are worth 2 (the mark, and the
    capital behind it), internal marks 1, casing commands one per word.
    """
    loaded = corpus.load(
        source="punctuation",
        limit=200,
        spoken_punctuation_rate=1.0,
        spoken_caps_rate=0.35,
        punctuation_only=True,
    )
    worth = [
        spoken_punctuation.effect(command, utterance.reference)
        for utterance in loaded.utterances
        for command in utterance.commands
    ]
    assert worth
    assert min(worth) >= 1, "a command that changes nothing measures nothing"
    assert max(worth) >= 2, "no command forces a capital, so the split is untested"


def test_undoing_a_command_is_what_ignoring_it_would_produce():
    reference, _, command = one_command()
    assert spoken_punctuation.undo(command, reference) == "Is it ready let me know either way."


def test_punctuation_only_leaves_nothing_but_commands_between_input_and_target():
    """The whole point of the mode: no score can be moved by disfluency removal.

    On a paired source that means discarding the verbatim side, so `nyra`'s hand-annotated
    disfluencies are not in the input at all.
    """
    loaded = corpus.load(
        source="punctuation", limit=200, spoken_punctuation_rate=1.0, punctuation_only=True
    )
    assert len(loaded) > 50
    for utterance in loaded.utterances:
        assert utterance.commands, "every row carries at least one command"
        assert all(op.startswith("spoken:") for op in utterance.operations)
        # Stated on the alignment rather than by reconstructing the input: on the content
        # axis the input must be the target plus command words and nothing else — no word
        # substituted, none dropped, and every addition a command. Marks and casing are
        # what the format axis sees, and they are the task.
        diff = metrics.align(
            metrics.normalize(utterance.reference), metrics.normalize(utterance.disfluent)
        )
        assert diff.substitutions == 0, utterance.disfluent
        assert diff.deletions == 0, utterance.disfluent
        assert all(word in utterance.command_words for word in diff.inserted), utterance.disfluent
    assert corpus.false_start_fraction(list(loaded.utterances)) == 0.0
    assert loaded.detail["punctuation_only"] is True


def test_punctuation_only_scores_a_perfect_cleanup_perfectly():
    loaded = corpus.load(
        source="punctuation", limit=200, spoken_punctuation_rate=1.0, punctuation_only=True
    )
    scored = metrics.mean([u.scored(u.reference) for u in loaded.utterances])
    assert scored["format"] == 1.0
    assert scored["content"] == 1.0


def test_punctuation_only_discards_a_paired_source_s_verbatim_side(monkeypatch):
    """`nyra`'s input side is its disfluent one; the mode has to reach past it."""
    rows = [
        {
            "verbatim_transcript": "um we shipped it today. uh Monday was quiet.",
            "intended_transcript": "We shipped it today. Monday was quiet, so nobody noticed.",
        }
    ]
    monkeypatch.setattr(corpus, "_rows_via_api", lambda *a, **k: iter(rows))
    loaded = corpus.load(
        source="nyra",
        limit=1,
        spoken_punctuation_rate=1.0,
        spoken_caps_rate=0.0,
        punctuation_only=True,
    )
    (utterance,) = loaded.utterances
    assert "um" not in metrics.normalize(utterance.disfluent)
    assert "uh" not in metrics.normalize(utterance.disfluent)
    assert utterance.commands


def test_punctuation_only_implies_a_rate_so_the_corpus_is_not_empty():
    """Without one the mode would load a corpus with no commands in it, which is the
    opposite of what it asks for."""
    assert cli.parse_args(["--punctuation-only"]).spoken_punctuation == 1.0
    assert cli.parse_args([]).spoken_punctuation == 0.0
    # An explicit rate still wins.
    assert (
        cli.parse_args(["--punctuation-only", "--spoken-punctuation", "0.5"]).spoken_punctuation
        == 0.5
    )


def test_the_punctuation_sample_is_all_internal_marks():
    """Its reason for existing apart from BUILTIN_SAMPLE, 55% of whose marks are final."""
    for text in corpus.PUNCTUATION_SAMPLE:
        tokens = text.split()
        internal = [
            i
            for i, raw in enumerate(tokens[:-1])
            if spoken_punctuation._split_mark(raw)
            and (
                metrics.normalize_text(raw[:-1]),
                raw[-1],
            )
            in spoken_punctuation.licensed_marks(text)
        ]
        assert internal, f"no internal mark to speak: {text!r}"


def test_the_punctuation_candidates_join_the_table_only_when_the_corpus_asks():
    """Keyed on the corpus, not the flag, so a frozen dataset read with --jsonl behaves
    the same as the corpus it was dumped from."""
    plain = corpus.load(source="builtin", limit=12)
    assert cli.instruction_table(plain) == dict(candidates.CANDIDATES)
    table = cli.instruction_table(corpus.load(jsonl=str(FROZEN_DATASET), limit=200))
    assert set(candidates.SPOKEN_PUNCTUATION_CANDIDATES) <= set(table)
    # The bar stays what Blurt ships, so the held-out comparison answers the product
    # question: what does teaching it the new task buy?
    assert candidates.BASELINE in table


def test_every_punctuation_candidate_is_shippable_and_keeps_the_safeguards():
    """Any of them can become the GEPA seed, and a seed the final gate would refuse
    wastes the whole search."""
    for name, text in candidates.SPOKEN_PUNCTUATION_CANDIDATES.items():
        assert candidates.overage(text) == 0, name
        assert candidates.missing_safeguards(text) == [], name


def test_an_oversized_punctuation_candidate_stops_the_run_too(monkeypatch):
    monkeypatch.setitem(candidates.SPOKEN_PUNCTUATION_CANDIDATES, "too-long", "x" * 5000)
    loaded = corpus.load(jsonl=str(FROZEN_DATASET), limit=200)
    with pytest.raises(SystemExit) as raised:
        cli.check_candidates(cli.instruction_table(loaded))
    assert "too-long" in str(raised.value)


def test_the_clause_fits_after_the_shipped_instruction():
    """That is the experiment `punct-appended` is: what can be taught for free?"""
    composite = candidates.SPOKEN_PUNCTUATION_CANDIDATES["punct-appended"]
    assert candidates.PRIOR_WINNER.split("\n\n")[0] in composite
    assert composite.endswith("Return only the cleaned transcript.")
    assert candidates.SPOKEN_PUNCTUATION_CLAUSE in composite
    assert candidates.overage(composite) == 0


def test_a_spoken_punctuation_run_selects_on_format_by_default():
    """Content casefolds and strips marks, so it cannot see most of this task."""
    plain = corpus.load(source="builtin", limit=12)
    spoken = corpus.load(jsonl=str(FROZEN_DATASET), limit=200)
    assert cli.resolve_axis(None, plain) == "blend"
    assert cli.resolve_axis(None, spoken) == "format"
    # An explicit choice still wins.
    assert cli.resolve_axis("content", spoken) == "content"


def test_a_spoken_punctuation_run_scores_the_bar_and_the_challengers():
    """Not `BASELINE` alone, and not the whole table.

    Alone it would search from an instruction that has never heard of the task; the whole
    table adds six terse instructions that rank framings of *disfluency* cleanup, none of
    which mentions punctuation, at 900 dev calls each.
    """
    loaded = corpus.load(jsonl=str(FROZEN_DATASET), limit=200)
    table = cli.instruction_table(loaded)
    scoring = cli.resolve_candidates(cli.parse_args([]), table, spoken=True)
    assert scoring[0] == candidates.BASELINE
    assert set(scoring) == {candidates.BASELINE, *candidates.SPOKEN_PUNCTUATION_CANDIDATES}
    assert set(scoring) < set(table)


def test_the_full_table_is_still_available_on_a_spoken_run():
    scoring = cli.resolve_candidates(
        cli.parse_args(["--candidates", "all"]),
        cli.instruction_table(corpus.load(jsonl=str(FROZEN_DATASET), limit=200)),
        spoken=True,
    )
    assert set(candidates.CANDIDATES) <= set(scoring)


def test_the_command_table_is_ordered_by_the_selecting_axis(capsys):
    """A candidate that converts more commands and still loses should read as that."""
    rows = [
        (
            "worse-text",
            dict.fromkeys(metrics.AXES, 0.1)
            | {
                "commands_converted": 0.9,
                "commands_literal": 0.05,
                "commands_missing": 0.05,
                "commands_total": 10.0,
            },
        ),
        (
            "better-text",
            dict.fromkeys(metrics.AXES, 0.9)
            | {
                "commands_converted": 0.2,
                "commands_literal": 0.4,
                "commands_missing": 0.4,
                "commands_total": 10.0,
            },
        ),
    ]
    cli.print_command_table(rows, "format")
    printed = capsys.readouterr().out
    assert printed.index("better-text") < printed.index("worse-text")


def test_the_command_table_is_silent_when_nothing_was_planted(capsys):
    cli.print_command_table([("x", dict.fromkeys(metrics.AXES, 0.5))], "format")
    assert capsys.readouterr().out == ""


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
