"""Scoring: how close did the cleanup get back to the reference?

Two word-error rates over the same alignment machinery:

- **content** — casefolded, punctuation-stripped. Measures whether the words the
  speaker meant survived and the disfluencies didn't. This is the axis the prompt
  is actually being tuned on, and the only one every corpus supports.
- **format** — tokens exactly as written. Adds capitalization and punctuation.
  Only meaningful on a corpus whose reference side carries them; `corpus.py`
  marks which sources qualify.

The default `blend` weights content 0.7 / format 0.3: punctuation differences are
numerous and mostly cosmetic, so scoring them equally would drown out the signal
about disfluency removal. `--metric content` or `--metric format` isolate either
axis when that's what you want to see.

This module is the bottom of the dependency chain — it imports nothing else in the
harness, so nothing about how a corpus was built can leak into how it is scored.
"""

from __future__ import annotations

import math
import re
import string
from dataclasses import dataclass

# The single definition of "punctuation" in the harness. The injector strips the
# same set when `--strip-formatting` is on, so a character added here changes what
# the input contains and what the content axis ignores in one edit — the two can't
# drift into scoring characters the input no longer has.
PUNCTUATION = string.punctuation + "—–…“”‘’"
_STRIP_PUNCTUATION = str.maketrans("", "", PUNCTUATION)

AXES = ("content", "format", "blend")


def normalize_text(text: str) -> str:
    """Casefold, drop punctuation, collapse whitespace — still a string."""
    return re.sub(r"\s+", " ", text.translate(_STRIP_PUNCTUATION).lower()).strip()


def normalize(text: str) -> list[str]:
    """Content tokens: casefolded, punctuation removed."""
    return normalize_text(text).split()


def surface(text: str) -> list[str]:
    """Tokens exactly as written — capitalization and punctuation intact."""
    return text.split()


@dataclass(frozen=True)
class Alignment:
    """The token-level diff between a reference and a hypothesis.

    Counts are derived from the token tuples rather than stored alongside them, so
    a count can never disagree with the diff it is supposed to summarize.
    """

    reference_length: int
    substituted: tuple[tuple[str, str], ...]
    deleted: tuple[str, ...]
    inserted: tuple[str, ...]

    @property
    def substitutions(self) -> int:
        return len(self.substituted)

    @property
    def deletions(self) -> int:
        return len(self.deleted)

    @property
    def insertions(self) -> int:
        return len(self.inserted)

    @property
    def error_rate(self) -> float:
        """Word error rate. An empty reference scores 0 unless the hypothesis added words."""
        if self.reference_length == 0:
            return 0.0 if self.insertions == 0 else 1.0
        return (self.substitutions + self.deletions + self.insertions) / self.reference_length


def align(reference: list[str], hypothesis: list[str]) -> Alignment:
    """Levenshtein alignment over tokens, keeping a backtrace for the diff.

    Full O(len(ref) * len(hyp)) DP table. Dictation utterances are a sentence or
    two, so the table is tiny and the readable implementation is the right one.
    `difflib` is deliberately not used: `SequenceMatcher` maximizes contiguous
    matching blocks rather than minimizing edits, so its output is not a word error
    rate and its `replace` opcodes span unequal ranges that don't decompose into
    substitution / deletion / insertion counts.
    """
    rows, cols = len(reference), len(hypothesis)
    cost = [[0] * (cols + 1) for _ in range(rows + 1)]
    for i in range(rows + 1):
        cost[i][0] = i
    for j in range(cols + 1):
        cost[0][j] = j
    for i in range(1, rows + 1):
        for j in range(1, cols + 1):
            if reference[i - 1] == hypothesis[j - 1]:
                cost[i][j] = cost[i - 1][j - 1]
            else:
                cost[i][j] = 1 + min(
                    cost[i - 1][j - 1],  # substitution
                    cost[i - 1][j],  # deletion (reference word missing)
                    cost[i][j - 1],  # insertion (hypothesis added a word)
                )

    substituted: list[tuple[str, str]] = []
    deleted: list[str] = []
    inserted: list[str] = []

    i, j = rows, cols
    while i > 0 or j > 0:
        if i > 0 and j > 0 and reference[i - 1] == hypothesis[j - 1]:
            i, j = i - 1, j - 1
        elif i > 0 and j > 0 and cost[i][j] == cost[i - 1][j - 1] + 1:
            substituted.append((reference[i - 1], hypothesis[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and cost[i][j] == cost[i - 1][j] + 1:
            deleted.append(reference[i - 1])
            i -= 1
        else:
            inserted.append(hypothesis[j - 1])
            j -= 1

    return Alignment(
        reference_length=rows,
        # The backtrace walks right-to-left; reverse so the diffs read in
        # sentence order when they land in feedback text.
        substituted=tuple(reversed(substituted)),
        deleted=tuple(reversed(deleted)),
        inserted=tuple(reversed(inserted)),
    )


@dataclass(frozen=True)
class Score:
    """One cleanup attempt, scored on both axes."""

    content: float
    format: float
    content_alignment: Alignment
    format_alignment: Alignment

    @property
    def blend(self) -> float:
        return 0.7 * self.content + 0.3 * self.format

    def value(self, axis: str) -> float:
        if axis not in AXES:
            raise ValueError(f"unknown axis {axis!r}; expected one of {', '.join(AXES)}")
        return getattr(self, axis)


#: Worst score any single attempt can reach, and what a crashed rollout is worth.
#: See `from_error_rate` for why the bottom is bounded rather than open.
WORST_SCORE = -1.0


def from_error_rate(rate: float) -> float:
    """Turn a word error rate into a score: `1 - WER`, with a bounded tail below zero.

    WER is unbounded above — a hypothesis can add arbitrarily many words — so `1 - WER`
    is unbounded below and something has to bound it. This used to be `max(0, ...)`,
    which bounded it by **flattening** it: at WER 1.0, 2.9 and 4.3 the score was 0.000,
    0.000 and 0.000. Three very different failures, one number.

    That flattening lands exactly where it hurts. GEPA's Pareto front is per validation
    example, so on any example where a candidate degenerates, "looped until it hit
    max_tokens" and "reworded a clause badly" were indistinguishable — the front could
    not prefer the near-miss, and the search got no gradient out of catastrophe.

    So the tail decays instead of clipping:

        WER <= 1   ->  1 - WER          exactly as before, in [0, 1]
        WER >  1   ->  exp(1 - WER) - 1 strictly decreasing, approaching -1

    Nothing in the normal range moves — a run that scored 0.848 still scores 0.848, so
    every number measured before this change stays comparable. Only the region that was
    previously one flat line gains an ordering.

    The two pieces meet cleanly at WER 1: both give 0, and both have slope -1 there, so
    there is no discontinuity for the optimizer to sit on. Zero keeps its meaning —
    "as bad as saying nothing at all", since an empty hypothesis deletes every reference
    word for a WER of exactly 1. Below zero now means what it says: worse than silence.
    """
    if rate <= 1.0:
        return 1.0 - rate
    # Bounded rather than open-ended: GEPA scores a crashed rollout with a fixed
    # `failure_score`, and a real output able to sink arbitrarily far would eventually
    # rank *below* a crash, which is not an ordering anyone wants.
    return math.exp(1.0 - rate) - 1.0


def score(reference: str, hypothesis: str) -> Score:
    """Score a cleanup against its reference on both axes — see `from_error_rate`."""
    content_alignment = align(normalize(reference), normalize(hypothesis))
    format_alignment = align(surface(reference), surface(hypothesis))
    return Score(
        content=from_error_rate(content_alignment.error_rate),
        format=from_error_rate(format_alignment.error_rate),
        content_alignment=content_alignment,
        format_alignment=format_alignment,
    )


def mean(scores: list[Score]) -> dict[str, float]:
    """Average every axis over a set of scored attempts; zeros for an empty set."""
    if not scores:
        return dict.fromkeys(AXES, 0.0)
    return {axis: sum(s.value(axis) for s in scores) / len(scores) for axis in AXES}


def feedback(
    reference: str,
    hypothesis: str,
    disfluent: str,
    scored: Score,
    instruction_budget: int | None = None,
) -> str:
    """Plain-language diff for GEPA's reflection step.

    GEPA rewrites the instruction from this text, so it names the failure mode
    ("left disfluencies in") rather than reporting a number the reflector can't act
    on. A perfect score returns praise rather than an empty string — an empty
    reflection prompt is worse than an uninformative one.

    Which extra words count as leftover disfluencies is decided by the pair itself:
    a word the hypothesis added that was present in the input is something the
    cleanup failed to remove, while a word in neither is something it invented.
    That reads the corpus rather than a fixed filler-word list, so it stays correct
    on real transcripts whose disfluencies nobody enumerated in advance.

    `instruction_budget` appends the length ceiling the rewritten instruction has to
    fit (`candidates.INSTRUCTION_CHARACTER_CAP`). It rides on every message, including
    the perfect-score one, because the reflector only ever sees this channel — a
    constraint mentioned on failures alone would be invisible exactly when a run is
    going well and the instruction is growing. Note what this is: *guidance*, not
    enforcement. A reflector can ignore it, and models count characters badly — the
    enforcement is `program.CappedInstructionProposer`, which rejects an over-cap
    proposal outright, and the CLI's final refusal behind it. What this buys is a
    likelier first attempt, and so fewer of the proposer's retries.
    """
    budget = (
        ""
        if instruction_budget is None
        else f" Write the instruction itself in at most {instruction_budget} characters."
    )
    if scored.content >= 1.0 and scored.format >= 1.0:
        return "Perfect: the cleaned text matches the reference exactly." + budget

    notes: list[str] = []
    content = scored.content_alignment
    spoken = set(normalize(disfluent))

    leftover = [word for word in content.inserted if word in spoken]
    invented = [word for word in content.inserted if word not in spoken]
    if leftover:
        notes.append(f"left disfluencies in the output: {', '.join(sorted(set(leftover)))}")
    if invented:
        notes.append(f"added words that were not in the transcript: {', '.join(invented[:8])}")
    if content.deleted:
        notes.append(f"dropped content words: {', '.join(content.deleted[:8])}")
    if content.substituted:
        rewrites = ", ".join(f"{was!r}->{now!r}" for was, now in content.substituted[:6])
        notes.append(f"reworded content instead of only cleaning it: {rewrites}")

    if not notes and scored.format < 1.0:
        notes.append(
            "wording is correct but capitalization or punctuation differs from the reference"
        )

    detail = "; ".join(notes) if notes else "output differs from the reference"
    return (
        f"Content score {scored.content:.2f}, formatting score {scored.format:.2f}. "
        f"The cleanup {detail}. "
        f"Reference: {reference!r}. Produced: {hypothesis!r}." + budget
    )
