"""Seeded disfluency injection.

Turns a clean reference transcript into the kind of verbatim text a speech-to-text
model returns when someone dictates off the cuff: fillers, repetitions, stutters,
false starts, and restarts.

The injector is **additive by construction** — every operator inserts tokens and
none rewrites or deletes reference content — so the reference is exactly
recoverable by deleting the inserted spans. That matters for the eval: it keeps
the ceiling at a perfect score, so a candidate prompt that loses points really did
lose them, rather than being charged for damage the injector did.

The one exception is opt-in: `strip_formatting` lowercases the utterance and drops
sentence punctuation, which makes restoring capitalization and punctuation part of
the task rather than a given. Every run is seeded, so a given (seed, index,
severity) always produces the same utterance.
"""

from __future__ import annotations

import random
import re
import string
from dataclasses import dataclass, field

# Fillers a dictation user actually produces. Single words first (most common),
# then the multi-word hedges — `weights` below mirrors that ordering.
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

_PUNCTUATION = str.maketrans("", "", string.punctuation + "—–…“”‘’")


@dataclass(frozen=True)
class Utterance:
    """One eval example: the clean target, the messy input, and what was done to it."""

    reference: str
    disfluent: str
    operations: tuple[str, ...] = field(default=())

    @property
    def is_modified(self) -> bool:
        return self.disfluent != self.reference


def _word_shape(token: str) -> str:
    """The token stripped of surrounding punctuation, for building stutters/repeats."""
    return token.strip(string.punctuation + "—–…“”‘’")


def _stutter(word: str, rng: random.Random) -> str | None:
    """`started` -> `st-`. Returns None for words too short to truncate audibly."""
    bare = _word_shape(word)
    if len(bare) < 4:
        return None
    cut = rng.randint(1, 2)
    return f"{bare[:cut].lower()}-"


def inject(
    reference: str,
    *,
    seed: int,
    severity: float = 0.35,
    strip_formatting: bool = False,
) -> Utterance:
    """Render `reference` as spontaneous speech.

    `severity` (0..1) scales the per-token-boundary chance of a disfluency; at the
    0.35 default roughly one word in eight picks one up, which is in the range a
    person dictating a paragraph without rehearsing it produces. 0 disables
    injection entirely (useful as a control arm).
    """
    if not 0.0 <= severity <= 1.0:
        raise ValueError(f"severity must be in 0..1, got {severity}")

    rng = random.Random(seed)
    tokens = reference.split()
    if not tokens:
        return Utterance(reference=reference, disfluent=reference)

    event_rate = 0.35 * severity
    out: list[str] = []
    operations: list[str] = []

    # A clause-initial hedge is its own (more likely) event: people start talking
    # before they have finished deciding what to say far more often than they
    # stumble mid-sentence.
    if rng.random() < min(0.9, severity * 1.2):
        opener = rng.choice(OPENERS)
        out.append(opener)
        operations.append("opener")
        # The reference's first word carried the sentence capital; it is now
        # mid-utterance, so lowercase it unless it looks like a proper noun
        # (all-caps or internally capitalized survives).
        first = tokens[0]
        if first[:1].isupper() and not first[1:2].isupper():
            tokens = [first[0].lower() + first[1:], *tokens[1:]]

    for index, token in enumerate(tokens):
        if rng.random() < event_rate:
            operation = rng.choices(
                ("filler", "repeat", "stutter", "false_start", "restart"),
                weights=(46, 20, 14, 10, 10),
            )[0]

            if operation == "filler":
                out.append(rng.choice(FILLERS))
            elif operation == "repeat":
                bare = _word_shape(token)
                if bare:
                    out.append(bare.lower() if index else bare)
                else:
                    operation = "skipped"
            elif operation == "stutter":
                fragment = _stutter(token, rng)
                if fragment:
                    out.append(fragment)
                else:
                    operation = "skipped"
            elif operation == "false_start":
                # Abandon a word borrowed from elsewhere in the sentence, then
                # correct back to the real one. The wrong word is always followed
                # by an explicit correction marker, so the intended text is still
                # unambiguous.
                pool = [_word_shape(t) for t in tokens if len(_word_shape(t)) > 3]
                if pool:
                    out.append(f"{rng.choice(pool).lower()}—")
                    out.append(rng.choice(CORRECTIONS))
                else:
                    operation = "skipped"
            elif operation == "restart":
                # Re-run the last couple of words, the way someone does after
                # losing the thread mid-clause.
                span = out[-rng.randint(2, 3) :]
                restart = [_word_shape(t) for t in span if _word_shape(t)]
                if restart:
                    out.extend(word.lower() for word in restart)
                else:
                    operation = "skipped"

            if operation != "skipped":
                operations.append(operation)

        out.append(token)

    disfluent = " ".join(out)
    if strip_formatting:
        disfluent = disfluent.translate(_PUNCTUATION).lower()
        disfluent = re.sub(r"\s+", " ", disfluent).strip()
        operations.append("strip_formatting")

    return Utterance(reference=reference, disfluent=disfluent, operations=tuple(operations))


def inject_all(
    references: list[str],
    *,
    seed: int,
    severity: float = 0.35,
    strip_formatting: bool = False,
) -> list[Utterance]:
    """`inject` over a corpus, deriving each example's seed from its position.

    Per-example seeds (rather than one shared generator) keep an utterance's
    disfluencies stable when the corpus around it changes — re-running with a
    larger `--limit` doesn't reshuffle the examples you already looked at.
    """
    return [
        inject(reference, seed=seed + index, severity=severity, strip_formatting=strip_formatting)
        for index, reference in enumerate(references)
    ]
