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

Inside an axis, every error costs the same by default — a left-in "um" and a left-in
abandoned false start are both one insertion. `--false-start-weight` breaks that tie:
the errors `false_start_residue` can attribute to a false start are multiplied by it,
so a run can be told that false starts matter more than fillers without changing what
the axes mean. It defaults to 1.0, which is arithmetically the old metric, so every
number recorded before it existed stays comparable.

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

# Trailing marks a transcriber writes for a word the speaker cut off mid-word —
# the one unambiguous orthographic signature of an abandoned start. `nyra` ships
# them as `th*`, which `corpus._detag_nyra` rewrites to `th-`; the injector writes
# `word—`. Matched against the *surface* token, because `normalize` strips exactly
# these characters before the content axis ever sees them.
CUTOFF_MARKS = ("-", "—", "–")

# Editing terms — what a speaker says between abandoning a phrase and restarting
# it, Switchboard's `{E}` class. Enumerated where fillers deliberately are not:
# fillers are open-ended and the feedback path reads them off the pair instead
# (see `feedback`), but a repair marker left in the output is false-start residue
# by definition, and there are four of them worth naming.
#
# `disfluency.CORRECTIONS` *is* this tuple, so the markers the injector writes and
# the markers scoring looks for cannot drift apart. The direction of that coupling
# is the same as `PUNCTUATION`'s — scoring defines it, corpus construction consumes
# it — but it does mean synthetic false starts are graded against a list the
# injector also read. On `builtin` that is a smoke test; on `nyra` the cut-offs
# come from hand annotation and no list of ours was involved.
EDITING_TERMS = ("I mean", "sorry", "or rather", "no wait")


def normalize_text(text: str) -> str:
    """Casefold, drop punctuation, collapse whitespace — still a string."""
    return re.sub(r"\s+", " ", text.translate(_STRIP_PUNCTUATION).lower()).strip()


def normalize(text: str) -> list[str]:
    """Content tokens: casefolded, punctuation removed."""
    return normalize_text(text).split()


def surface(text: str) -> list[str]:
    """Tokens exactly as written — capitalization and punctuation intact."""
    return text.split()


def false_start_residue(disfluent: str, reference: str) -> frozenset[str]:
    """Content tokens of `disfluent` that a false start left behind, if any survive.

    A false start is a speaker abandoning a phrase and restarting it, and two parts
    of one are visible without knowing where the reparandum ended:

    - the **cut-off word** the speaker stopped inside (`th-`, `sec—`), and
    - the **editing term** they restarted with (`I mean`, `sorry`).

    Both are things a correct cleanup deletes outright, so an output that still
    contains one is a false start the instruction did not catch. That is the
    complaint `--false-start-weight` exists to price, and it is priced on tokens
    rather than on whole utterances so that "solved the utterance but left the
    false start in" is charged and "left an `um` in" is not.

    A cut-off word covers the injector's `stutter` as well as its `false_start`, and
    that grouping is deliberate: both are a word the speaker did not finish, both must
    be deleted outright, and no transcript says which intention produced the fragment.

    Tokens the reference itself contains are excluded: those are words the speaker
    meant, so an error touching one is ordinary rewording, not leftover residue —
    which matters most for the `i` in `I mean`, a word half the corpus's references
    legitimately start with.

    What this does **not** see is an abandoned *whole* content word with no cut-off
    and no marker ("go to the store the mall"). Separating that from a filler needs
    the filler list this harness refuses to keep, so it stays at weight 1.0 and the
    weighting under-counts rather than guessing.
    """
    marked: set[str] = set()
    for token in surface(disfluent):
        if token.endswith(CUTOFF_MARKS):
            marked.update(normalize(token))

    padded = f" {normalize_text(disfluent)} "
    for term in EDITING_TERMS:
        if f" {normalize_text(term)} " in padded:
            marked.update(normalize(term))

    return frozenset(marked - set(normalize(reference)))


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
    def hypothesis_side(self) -> tuple[str, ...]:
        """Every token the cleanup emitted that the reference did not want there.

        Insertions plus the incoming half of each substitution. These are the only
        errors a residue set can classify, because they are the only ones carrying a
        token the cleanup chose to keep.
        """
        return (*self.inserted, *(now for _, now in self.substituted))

    @property
    def error_rate(self) -> float:
        """Word error rate. An empty reference scores 0 unless the hypothesis added words."""
        return self.weighted_error_rate()

    def weighted_error_rate(
        self, residue: frozenset[str] = frozenset(), weight: float = 1.0
    ) -> float:
        """Word error rate charging `weight` for each error that is false-start residue.

        Only the **hypothesis side** of an error can be residue: a token the cleanup
        emitted that the input marked as abandoned (`residue`, from
        `false_start_residue`). That covers both ways a missed false start shows up —
        inserted next to the repair (`the store I mean the mall`), or substituted for
        it when the repair is dropped instead (`the store`).

        Deletions are charged flat. A dropped reference word is the cleanup deleting
        something the speaker meant, and attributing that to a false start would need
        to know where the reparandum ended, which nothing here does.

        `weight=1.0` reproduces plain WER exactly, which is why the unweighted
        `error_rate` is this method rather than a second formula beside it.
        """
        if self.reference_length == 0:
            # A flag, not a count — nothing to scale, and no reference to divide by.
            return 0.0 if self.insertions == 0 else 1.0
        charged = self.deletions + sum(
            weight if normalize_text(token) in residue else 1.0 for token in self.hypothesis_side
        )
        return charged / self.reference_length

    def residue_errors(self, residue: frozenset[str]) -> int:
        """How many hypothesis-side errors `residue` accounts for — the weighted ones."""
        return sum(normalize_text(token) in residue for token in self.hypothesis_side)


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
    #: Content-axis errors attributed to a false start the cleanup missed. Counted
    #: whatever the weight is, so "how often does this instruction miss a false
    #: start" is answerable from a default run rather than only from a weighted one.
    false_start_errors: int = 0

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


def score(
    reference: str,
    hypothesis: str,
    *,
    spoken: str | None = None,
    false_start_weight: float = 1.0,
) -> Score:
    """Score a cleanup against its reference on both axes — see `from_error_rate`.

    `spoken` is the disfluent input the cleanup was given. Only it can say which of
    the output's errors are residue from a false start rather than words the model
    invented, so weighting is unavailable without it — and asking for a weight
    without one raises rather than quietly scoring flat. Passing it with the default
    weight is free and fills in `false_start_errors`.
    """
    if false_start_weight < 0.0:
        raise ValueError(f"false_start_weight must not be negative, got {false_start_weight}")
    if spoken is None and false_start_weight != 1.0:
        raise ValueError(
            "false_start_weight needs the disfluent input to attribute errors to a "
            "false start; pass spoken=<the text the cleanup was given>"
        )

    residue = frozenset() if spoken is None else false_start_residue(spoken, reference)
    content_alignment = align(normalize(reference), normalize(hypothesis))
    format_alignment = align(surface(reference), surface(hypothesis))
    return Score(
        content=from_error_rate(content_alignment.weighted_error_rate(residue, false_start_weight)),
        format=from_error_rate(format_alignment.weighted_error_rate(residue, false_start_weight)),
        content_alignment=content_alignment,
        format_alignment=format_alignment,
        false_start_errors=content_alignment.residue_errors(residue),
    )


def mean(scores: list[Score]) -> dict[str, float]:
    """Average every axis over a set of scored attempts; zeros for an empty set."""
    if not scores:
        return dict.fromkeys(AXES, 0.0)
    return {axis: sum(s.value(axis) for s in scores) / len(scores) for axis in AXES}


def feedback(
    reference: str,
    disfluent: str,
    scored: Score,
    axis: str = "content",
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

    Leftovers `false_start_residue` can attribute to a false start are pulled out of
    that line and reported first, as a false start. The scoring weight and this split
    are independent on purpose: the weight decides what a miss *costs*, and this
    decides whether the reflector can tell it apart from a filler it left in. A
    reflector told only "left disfluencies in: mean" writes another filler clause.

    Three things are deliberately **not** here, because the reflector already has them
    or is misled by them:

    - **The produced text.** GEPA's reflective dataset carries it as "Generated
      Outputs" next to the input, so repeating it is tokens for nothing — which is why
      this takes no `hypothesis` argument at all; `scored` already carries the diff.
      The reference is the one thing GEPA does not show, which is why that stays.
    - **The length budget.** It belongs in `candidates.constraint_preamble`, said once
      with the real target, not repeated on all eight examples of a minibatch — and
      said there in words against a target *below* the cap, which is the opposite of
      what a per-example "at most 2048 characters" was teaching. One run's rejected
      proposals had a median length of 2149 against that 2048.
    - **The axis nobody selected on.** Only `axis` is reported. Naming the formatting
      score on a corpus whose formatting the harness refuses to trust — `--metric
      blend` degrades to `content` on a corpus with unreliable target casing —
      invites the reflector to chase capitalization that is an artifact of how the
      targets were built.
    """
    if scored.value(axis) >= 1.0:
        return "Perfect: the cleaned text matches the reference exactly."

    notes: list[str] = []
    content = scored.content_alignment
    spoken = set(normalize(disfluent))
    residue = false_start_residue(disfluent, reference)

    # False starts first, and named as what they are. "left disfluencies in: th-, mean"
    # reads to the reflector as another filler it missed, so it writes another filler
    # clause; the failure it should be writing about is that the speaker abandoned a
    # phrase and the cleanup kept the abandoned half.
    abandoned = sorted({word for word in content.inserted if word in residue})
    kept_instead = [(was, now) for was, now in content.substituted if now in residue]
    leftover = [word for word in content.inserted if word in spoken and word not in residue]
    invented = [word for word in content.inserted if word not in spoken]
    if abandoned:
        notes.append(
            "left a false start in the output — the speaker abandoned these and restarted, "
            f"so they should have been deleted with the words they replaced: {', '.join(abandoned)}"
        )
    if kept_instead:
        pairs = ", ".join(f"{now!r} instead of {was!r}" for was, now in kept_instead[:6])
        notes.append(f"kept the abandoned half of a false start rather than the restart: {pairs}")
    if leftover:
        notes.append(f"left disfluencies in the output: {', '.join(sorted(set(leftover)))}")
    if invented:
        notes.append(f"added words that were not in the transcript: {', '.join(invented[:8])}")
    if content.deleted:
        notes.append(f"dropped content words: {', '.join(content.deleted[:8])}")
    # Whatever `kept_instead` already reported as a false start is not also a
    # rewording — the reflector acting on one note per failure is the point.
    reworded = [pair for pair in content.substituted if pair not in kept_instead]
    if reworded:
        rewrites = ", ".join(f"{was!r}->{now!r}" for was, now in reworded[:6])
        notes.append(f"reworded content instead of only cleaning it: {rewrites}")

    if not notes and scored.format < 1.0:
        notes.append(
            "wording is correct but capitalization or punctuation differs from the reference"
        )

    detail = "; ".join(notes) if notes else "output differs from the reference"
    return (
        f"Score {scored.value(axis):.2f} ({axis}). The cleanup {detail}. Reference: {reference!r}."
    )
