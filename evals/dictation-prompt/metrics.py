"""Scoring: how close did the cleanup get back to the reference?

Two word-error rates over the same alignment machinery:

- **content** — casefolded, punctuation-stripped. Measures whether the words the
  speaker meant survived and the disfluencies didn't. This is the axis the prompt
  is actually being tuned on.
- **format** — tokens exactly as written. Adds capitalization and punctuation,
  which is what `--strip-formatting` runs make the model responsible for.

The default `blend` weights content 0.7 / format 0.3: punctuation differences are
numerous and mostly cosmetic, so scoring them equally would drown out the signal
about disfluency removal. `--metric content` or `--metric format` isolate either
axis when that's what you want to see.
"""

from __future__ import annotations

import re
import string
from dataclasses import dataclass

from disfluency import CORRECTIONS, FILLERS, OPENERS

_PUNCTUATION = str.maketrans("", "", string.punctuation + "—–…“”‘’")

# Words that are *supposed* to disappear. Used only to phrase feedback ("left
# filler words: um, like") — never to score, since a filler can legitimately be
# reference content ("I like this").
_DISFLUENCY_WORDS = frozenset(
    word
    for phrase in (*FILLERS, *OPENERS, *CORRECTIONS)
    for word in phrase.lower().split()
)


def normalize(text: str) -> list[str]:
    """Content tokens: casefolded, punctuation removed, whitespace collapsed."""
    stripped = text.translate(_PUNCTUATION).lower()
    return re.sub(r"\s+", " ", stripped).strip().split()


def surface(text: str) -> list[str]:
    """Tokens exactly as written — capitalization and punctuation intact."""
    return text.split()


@dataclass(frozen=True)
class Alignment:
    """Edit counts plus the actual differing tokens, for feedback text."""

    substitutions: int
    deletions: int
    insertions: int
    reference_length: int
    substituted: tuple[tuple[str, str], ...]
    deleted: tuple[str, ...]
    inserted: tuple[str, ...]

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

    substitutions = deletions = insertions = 0
    substituted: list[tuple[str, str]] = []
    deleted: list[str] = []
    inserted: list[str] = []

    i, j = rows, cols
    while i > 0 or j > 0:
        if i > 0 and j > 0 and reference[i - 1] == hypothesis[j - 1]:
            i, j = i - 1, j - 1
        elif i > 0 and j > 0 and cost[i][j] == cost[i - 1][j - 1] + 1:
            substitutions += 1
            substituted.append((reference[i - 1], hypothesis[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and cost[i][j] == cost[i - 1][j] + 1:
            deletions += 1
            deleted.append(reference[i - 1])
            i -= 1
        else:
            insertions += 1
            inserted.append(hypothesis[j - 1])
            j -= 1

    return Alignment(
        substitutions=substitutions,
        deletions=deletions,
        insertions=insertions,
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
    blend: float
    content_alignment: Alignment
    format_alignment: Alignment

    def value(self, metric: str) -> float:
        if metric == "content":
            return self.content
        if metric == "format":
            return self.format
        if metric == "blend":
            return self.blend
        raise ValueError(f"unknown metric {metric!r}; expected content, format, or blend")


def score(reference: str, hypothesis: str) -> Score:
    """Score a cleanup against its reference on both axes.

    Each axis is `1 - WER`, floored at 0: a hypothesis can be arbitrarily worse
    than the reference (WER is unbounded above), but "worse than saying nothing"
    is not a distinction the optimizer needs to rank.
    """
    content_alignment = align(normalize(reference), normalize(hypothesis))
    format_alignment = align(surface(reference), surface(hypothesis))
    content = max(0.0, 1.0 - content_alignment.error_rate)
    formatting = max(0.0, 1.0 - format_alignment.error_rate)
    return Score(
        content=content,
        format=formatting,
        blend=0.7 * content + 0.3 * formatting,
        content_alignment=content_alignment,
        format_alignment=format_alignment,
    )


def feedback(reference: str, hypothesis: str, scored: Score) -> str:
    """Plain-language diff for GEPA's reflection step.

    GEPA rewrites the instruction from this text, so it names the failure mode
    ("left filler words") rather than reporting a number the reflector can't act
    on. A perfect score returns praise rather than an empty string — an empty
    reflection prompt is worse than an uninformative one.
    """
    if scored.content >= 1.0 and scored.format >= 1.0:
        return "Perfect: the cleaned text matches the reference exactly."

    notes: list[str] = []
    content = scored.content_alignment

    leftover = [word for word in content.inserted if word in _DISFLUENCY_WORDS]
    other_extra = [word for word in content.inserted if word not in _DISFLUENCY_WORDS]
    if leftover:
        notes.append(f"left disfluencies in the output: {', '.join(sorted(set(leftover)))}")
    if other_extra:
        notes.append(f"added words the speaker did not say: {', '.join(other_extra[:8])}")
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
