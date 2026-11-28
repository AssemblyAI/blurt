"""Seeded disfluency injection — the synthetic corpus source.

Turns a clean reference transcript into the kind of verbatim text a speech-to-text
model returns when someone dictates off the cuff: fillers, repetitions, stutters,
false starts, and restarts.

Prefer a real paired corpus where one exists (see `corpus.py`) — real disfluencies
come from real speakers and this injector only knows the ones it was taught. What
injection buys that a fixed corpus can't:

- a **severity dial**, for checking whether a prompt's ranking survives more or
  less disfluent input;
- a **punctuation-restoration** task via `strip_formatting`, which no real paired
  corpus in `corpus.py` supports (their inputs and targets are punctuated alike);
- an **offline path**, so the pipeline is testable with no network.

Injection is additive by construction — every operator inserts tokens and none
rewrites or deletes reference content — so the reference is exactly recoverable by
deleting the inserted spans, and the ceiling stays at a perfect score. A candidate
that loses points really did lose them rather than being charged for damage the
injector did. `strip_formatting` is the deliberate exception: it lowercases and
unpunctuates, making formatting restoration part of the task.
"""

from __future__ import annotations

import random
from typing import Literal, assert_never

import metrics

# Fillers a dictation user actually produces. Single words first (most common),
# then the multi-word hedges — `weights` in `inject` mirrors that ordering.
FILLERS: tuple[str, ...] = (
    "um",
    "uh",
    "er",
    "ah",
    "hmm",
    "like",
    "you know",
    "I mean",
    "sort of",
    "kind of",
    "basically",
    "actually",
    "right",
)

# Clause-initial throat-clearing — "so, ...", "okay so, ...".
OPENERS: tuple[str, ...] = ("so", "okay so", "yeah so", "well", "right so", "I mean", "let's see")

# Markers a speaker uses when abandoning a phrase and restarting it.
CORRECTIONS: tuple[str, ...] = ("I mean", "sorry", "or rather", "no wait")

# Weighted toward fillers and repetitions because that is how spontaneous speech
# is distributed — Switchboard is over half repetitions. Note the consequence:
# corrections and restarts, the hard cases, are under-represented here relative to
# a corpus like Disfl-QA that was built specifically to contain them.
Operation = Literal["filler", "repeat", "stutter", "false_start", "restart"]
_OPERATIONS: tuple[Operation, ...] = ("filler", "repeat", "stutter", "false_start", "restart")
_WEIGHTS = (46, 20, 14, 10, 10)


def _word_shape(token: str) -> str:
    """The token stripped of surrounding punctuation, for building stutters/repeats."""
    return token.strip(metrics.PUNCTUATION)


def _mid_utterance(word: str) -> str:
    """`word` lowercased for a mid-utterance repeat, except the pronoun `I` and its
    contractions, which a real transcript capitalizes wherever they sit — inside a
    re-run multi-word filler ("I mean") just as much as standing alone."""
    return " ".join(
        token if _word_shape(token) == "I" or _word_shape(token).startswith("I'") else token.lower()
        for token in word.split()
    )


def _stutter(word: str, rng: random.Random) -> str | None:
    """`started` -> `st-`. Returns None for words too short to truncate audibly."""
    bare = _word_shape(word)
    if len(bare) < 4:
        return None
    return f"{bare[: rng.randint(1, 2)].lower()}-"


def inject(
    reference: str,
    *,
    seed: int,
    severity: float = 0.35,
    strip_formatting: bool = False,
) -> tuple[str, tuple[str, ...]]:
    """Render `reference` as spontaneous speech.

    Returns the disfluent text and the operators that produced it. `severity`
    (0..1) scales the per-token-boundary chance of a disfluency; at the 0.35
    default roughly one word in eight picks one up, which is in the range a person
    dictating a paragraph without rehearsing it produces. 0 disables injection
    entirely, which is the control arm.
    """
    if not 0.0 <= severity <= 1.0:
        raise ValueError(f"severity must be in 0..1, got {severity}")

    rng = random.Random(seed)
    tokens = reference.split()
    if not tokens:
        return reference, ()

    event_rate = 0.35 * severity
    out: list[str] = []
    operations: list[str] = []

    # A clause-initial hedge is its own (more likely) event: people start talking
    # before they have finished deciding what to say far more often than they
    # stumble mid-sentence.
    if rng.random() < min(0.9, severity * 1.2):
        out.append(rng.choice(OPENERS))
        operations.append("opener")
        # The reference's first word carried the sentence capital; it is now
        # mid-utterance, so lowercase it unless it looks like a proper noun
        # (all-caps or internally capitalized survives).
        first = tokens[0]
        if first[:1].isupper() and not first[1:2].isupper() and _mid_utterance(first) != first:
            tokens = [first[0].lower() + first[1:], *tokens[1:]]

    # Loop-invariant: the pool a false start borrows its abandoned word from
    # depends only on the (now final) token list.
    borrowable = [shape for shape in map(_word_shape, tokens) if len(shape) > 3]

    for index, token in enumerate(tokens):
        if rng.random() < event_rate:
            operation = rng.choices(_OPERATIONS, weights=_WEIGHTS)[0]
            # False when the operator had nothing to work on here, so it isn't recorded.
            applied = True

            match operation:
                case "filler":
                    out.append(rng.choice(FILLERS))
                case "repeat":
                    bare = _word_shape(token)
                    applied = bool(bare)
                    if bare:
                        out.append(_mid_utterance(bare) if index else bare)
                case "stutter":
                    fragment = _stutter(token, rng)
                    applied = fragment is not None
                    if fragment:
                        out.append(fragment)
                case "false_start":
                    # Abandon a word borrowed from elsewhere in the sentence, then
                    # correct back to the real one. The wrong word is always followed
                    # by an explicit correction marker, so the intended text is still
                    # unambiguous.
                    applied = bool(borrowable)
                    if borrowable:
                        out.append(f"{rng.choice(borrowable).lower()}—")
                        out.append(rng.choice(CORRECTIONS))
                case "restart":
                    # Re-run the last couple of words, the way someone does after
                    # losing the thread mid-clause.
                    tail = out[-rng.randint(2, 3) :]
                    restart = [shape for shape in map(_word_shape, tail) if shape]
                    applied = bool(restart)
                    out.extend(_mid_utterance(word) for word in restart)
                case _:
                    # A new `Operation` without a case here fails mypy, not a run.
                    assert_never(operation)

            if applied:
                operations.append(operation)

        out.append(token)

    disfluent = " ".join(out)
    if strip_formatting:
        disfluent = metrics.normalize_text(disfluent)
        operations.append("strip_formatting")

    return disfluent, tuple(operations)
