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


def score(reference: str, hypothesis: str) -> Score:
    """Score a cleanup against its reference on both axes.

    Each axis is `1 - WER`, floored at 0: a hypothesis can be arbitrarily worse
    than the reference (WER is unbounded above), but "worse than saying nothing"
    is not a distinction the optimizer needs to rank.
    """
    content_alignment = align(normalize(reference), normalize(hypothesis))
    format_alignment = align(surface(reference), surface(hypothesis))
    return Score(
        content=max(0.0, 1.0 - content_alignment.error_rate),
        format=max(0.0, 1.0 - format_alignment.error_rate),
        content_alignment=content_alignment,
        format_alignment=format_alignment,
    )


def mean(scores: list[Score]) -> dict[str, float]:
    """Average every axis over a set of scored attempts; zeros for an empty set."""
    if not scores:
        return dict.fromkeys(AXES, 0.0)
    return {axis: sum(s.value(axis) for s in scores) / len(scores) for axis in AXES}


def feedback(reference: str, hypothesis: str, disfluent: str, scored: Score) -> str:
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
    """
    if scored.content >= 1.0 and scored.format >= 1.0:
        return "Perfect: the cleaned text matches the reference exactly."

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
        notes.append("wording is correct but capitalization or punctuation differs from the reference")

    detail = "; ".join(notes) if notes else "output differs from the reference"
    return (
        f"Content score {scored.content:.2f}, formatting score {scored.format:.2f}. "
        f"The cleanup {detail}. "
        f"Reference: {reference!r}. Produced: {hypothesis!r}."
    )
