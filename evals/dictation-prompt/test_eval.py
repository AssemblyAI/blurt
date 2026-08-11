"""Offline tests for the data and scoring halves of the eval.

These need no network and no API key: they pin the properties the results depend
on — that injection is deterministic and additive, that the metric bottoms out and
tops out where it should, and that the splits are disjoint. Run with:

    python -m pytest evals/dictation-prompt/test_eval.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import corpus  # noqa: E402
import metrics  # noqa: E402
import optimize_cleanup_prompt as evaluation  # noqa: E402
from disfluency import FILLERS, inject, inject_all  # noqa: E402

SENTENCE = (
    "The build failed because the signing certificate expired over the weekend "
    "and nobody noticed until Monday morning."
)


# --------------------------------------------------------------------------
# Disfluency injection
# --------------------------------------------------------------------------


def test_injection_is_deterministic_for_a_seed():
    first = inject(SENTENCE, seed=11, severity=0.5)
    second = inject(SENTENCE, seed=11, severity=0.5)
    assert first.disfluent == second.disfluent
    assert first.operations == second.operations


def test_different_seeds_produce_different_utterances():
    variants = {inject(SENTENCE, seed=seed, severity=0.5).disfluent for seed in range(12)}
    assert len(variants) > 1


def test_severity_zero_leaves_the_reference_alone():
    utterance = inject(SENTENCE, seed=3, severity=0.0)
    assert utterance.disfluent == SENTENCE
    assert utterance.operations == ()


def test_higher_severity_injects_more():
    light = len(inject(SENTENCE, seed=5, severity=0.15).disfluent.split())
    heavy = len(inject(SENTENCE, seed=5, severity=0.9).disfluent.split())
    assert heavy > light


def test_injection_only_adds_tokens():
    """Every reference word must survive, in order — the eval's ceiling depends on it."""
    for seed in range(40):
        utterance = inject(SENTENCE, seed=seed, severity=0.8)
        reference = metrics.normalize(utterance.reference)
        produced = metrics.normalize(utterance.disfluent)
        alignment = metrics.align(reference, produced)
        assert alignment.deletions == 0, utterance.disfluent
        assert alignment.substitutions == 0, utterance.disfluent


def test_strip_formatting_removes_case_and_punctuation():
    utterance = inject(SENTENCE, seed=2, severity=0.3, strip_formatting=True)
    assert utterance.disfluent == utterance.disfluent.lower()
    assert "." not in utterance.disfluent
    assert "strip_formatting" in utterance.operations


def test_inject_all_seeds_each_example_independently():
    """An example's disfluencies must not depend on how many came after it."""
    references = [SENTENCE, "Please send the revised figures before the review.", SENTENCE]
    short = inject_all(references[:2], seed=100, severity=0.6)
    long = inject_all(references, seed=100, severity=0.6)
    assert [u.disfluent for u in short] == [u.disfluent for u in long[:2]]


def test_injected_fillers_are_recognized_as_disfluencies():
    utterance = inject(SENTENCE, seed=1, severity=1.0)
    tokens = set(metrics.normalize(utterance.disfluent))
    assert tokens & {word.lower() for filler in FILLERS for word in filler.split()}


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------


def test_identical_text_scores_perfectly():
    scored = metrics.score(SENTENCE, SENTENCE)
    assert scored.content == 1.0
    assert scored.format == 1.0
    assert scored.blend == 1.0


def test_case_and_punctuation_split_the_two_axes():
    scored = metrics.score("Ship it on Friday.", "ship it on friday")
    assert scored.content == 1.0
    assert scored.format < 1.0


def test_uncleaned_transcript_scores_below_the_reference():
    utterance = inject(SENTENCE, seed=9, severity=0.7)
    assert metrics.score(utterance.reference, utterance.disfluent).content < 1.0


def test_a_perfect_cleanup_beats_the_uncleaned_transcript():
    utterance = inject(SENTENCE, seed=9, severity=0.7)
    cleaned = metrics.score(utterance.reference, utterance.reference)
    echoed = metrics.score(utterance.reference, utterance.disfluent)
    assert cleaned.blend > echoed.blend


def test_score_is_floored_at_zero():
    scored = metrics.score("yes", "a completely unrelated sentence that rambles on and on")
    assert scored.content == 0.0
    assert scored.blend >= 0.0


def test_alignment_reports_the_actual_diff():
    alignment = metrics.align(["ship", "it", "friday"], ["um", "ship", "it", "monday"])
    assert alignment.insertions == 1
    assert alignment.substitutions == 1
    assert alignment.deletions == 0
    assert "um" in alignment.inserted
    assert ("friday", "monday") in alignment.substituted


def test_empty_hypothesis_loses_every_word():
    scored = metrics.score(SENTENCE, "")
    assert scored.content == 0.0


def test_feedback_names_leftover_disfluencies():
    reference = "Ship it on Friday."
    hypothesis = "Um, ship it on Friday."
    note = metrics.feedback(reference, hypothesis, metrics.score(reference, hypothesis))
    assert "left disfluencies" in note
    assert "um" in note.lower()


def test_feedback_names_dropped_content():
    reference = "Ship the revised build on Friday."
    hypothesis = "Ship on Friday."
    note = metrics.feedback(reference, hypothesis, metrics.score(reference, hypothesis))
    assert "dropped content words" in note


def test_feedback_on_a_perfect_cleanup_is_not_empty():
    note = metrics.feedback(SENTENCE, SENTENCE, metrics.score(SENTENCE, SENTENCE))
    assert note.strip()


# --------------------------------------------------------------------------
# Corpus loading
# --------------------------------------------------------------------------


def test_builtin_corpus_loads_offline():
    loaded = corpus.load(source="builtin", limit=5)
    assert len(loaded) == 5
    assert all(text[-1] in ".?!" for text in loaded.references)


def test_corpus_rejects_short_and_unpunctuated_references():
    assert corpus._usable("too short") is None
    assert corpus._usable("this sentence is long enough but has no terminal mark at all") is None
    assert corpus._usable("This sentence is long enough and ends properly right here.") is not None


def test_jsonl_loader_accepts_both_shapes(tmp_path):
    path = tmp_path / "refs.jsonl"
    path.write_text(
        '{"reference": "The build failed because the certificate expired over the weekend."}\n'
        "Please send the revised figures over before tomorrow's review meeting.\n",
        encoding="utf-8",
    )
    loaded = corpus.load(jsonl=str(path), limit=10)
    assert len(loaded) == 2
    assert loaded.source == "jsonl"


def test_corpus_deduplicates():
    loaded = corpus.load(jsonl=None, source="builtin", limit=100)
    assert len(set(loaded.references)) == len(loaded.references)


# --------------------------------------------------------------------------
# Splitting and floors
# --------------------------------------------------------------------------


def test_splits_are_disjoint_and_complete():
    utterances = inject_all(list(corpus.BUILTIN_SAMPLE), seed=4, severity=0.4)
    split = evaluation.split_examples(utterances, seed=4, dev_fraction=0.3, test_fraction=0.3)
    everything = split.train + split.dev + split.test
    assert len(everything) == len(utterances)
    assert len({u.disfluent for u in everything}) == len(utterances)


def test_splitting_is_stable_for_a_seed():
    utterances = inject_all(list(corpus.BUILTIN_SAMPLE), seed=4, severity=0.4)
    first = evaluation.split_examples(utterances, seed=4, dev_fraction=0.3, test_fraction=0.3)
    second = evaluation.split_examples(utterances, seed=4, dev_fraction=0.3, test_fraction=0.3)
    assert [u.disfluent for u in first.test] == [u.disfluent for u in second.test]


def test_echo_floor_sits_below_a_perfect_cleanup():
    utterances = inject_all(list(corpus.BUILTIN_SAMPLE), seed=6, severity=0.5)
    floor = evaluation.echo_floor(utterances, "blend")
    ceiling = evaluation.mean_score([(u.reference, u.reference) for u in utterances], "blend")
    assert 0.0 < floor < ceiling == 1.0


def test_every_candidate_instruction_is_a_nonempty_string():
    assert "default-proxy" in evaluation.CANDIDATES
    for name, instruction in evaluation.CANDIDATES.items():
        assert instruction.strip(), name
        # The dictation API documents a 4096-character cap on the request config's
        # prompt; keep every candidate comfortably shippable within one request.
        assert len(instruction) < 1000, name


def test_dry_run_completes_without_a_model():
    exit_code = evaluation.main(
        ["--source", "builtin", "--dry-run", "--limit", "12", "--show-samples", "1"]
    )
    assert exit_code == 0
