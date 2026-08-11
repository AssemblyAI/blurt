"""Offline tests for the corpus and scoring halves of the eval.

These need no network and no API key: they pin the properties the results depend
on — that injection is deterministic and additive, that the metric bottoms out and
tops out where it should, that de-tagging turns annotation conventions into
transcript text, and that the splits are disjoint. Run with:

    python3 -m pytest evals/dictation-prompt/test_eval.py
"""

from __future__ import annotations

import sys

import pytest

import candidates
import corpus
import metrics
import optimize_cleanup_prompt as cli
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
    assert corpus._usable_reference("Long enough and ends properly right here now.", for_injection=True)
    assert not corpus._usable_reference("no terminal punctuation on this one here", for_injection=True)
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


def test_echo_floor_sits_below_a_perfect_cleanup():
    loaded = corpus.load(source="builtin", limit=12, seed=6, severity=0.5)
    floor = corpus.echo_floor(list(loaded.utterances))
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
# Candidates and the offline guarantee
# --------------------------------------------------------------------------


def test_every_candidate_instruction_is_shippable():
    assert candidates.BASELINE in candidates.CANDIDATES
    for name, instruction in candidates.CANDIDATES.items():
        assert instruction.strip(), name
        # Comfortably inside the request config's documented 4096-character cap
        # (TranscriptionPrompt.characterCap on the Swift side) — this bound is the
        # eval's own, to keep candidates readable as a single instruction.
        assert len(instruction) < 1000, name


def test_dry_run_completes_without_importing_dspy():
    """The offline promise is structural: nothing on this path may pull in DSPy."""
    sys.modules.pop("program", None)
    assert cli.main(["--source", "builtin", "--dry-run", "--limit", "12", "--show-samples", "1"]) == 0
    assert "dspy" not in sys.modules
