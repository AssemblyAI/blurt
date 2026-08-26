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

Both axes carry one deliberate departure from plain WER: a **false start the cleanup
failed to remove** is charged `FALSE_START_WEIGHT` errors rather than one. See that
constant for why an equal charge left the search with no reason to care.

This module is the bottom of the dependency chain — it imports nothing else in the
harness, so nothing about how a corpus was built can leak into how it is scored.
"""

from __future__ import annotations

import math
import re
import string
from collections import Counter
from dataclasses import dataclass

# The single definition of "punctuation" in the harness. The injector strips the
# same set when `--strip-formatting` is on, so a character added here changes what
# the input contains and what the content axis ignores in one edit — the two can't
# drift into scoring characters the input no longer has.
PUNCTUATION = string.punctuation + "—–…“”‘’"
_STRIP_PUNCTUATION = str.maketrans("", "", PUNCTUATION)

AXES = ("content", "format", "blend")

#: Characters a token ends on when the speaker broke the word off mid-utterance —
#: `th-`, `ha-`, `store—`. Both corpora produce them: `corpus._detag_nyra` rewrites
#: Switchboard's `th*` cut-off convention into `th-`, and the injector emits `st-` for
#: a stutter and `word—` for an abandoned one. It is the one abandonment signal that
#: needs no vocabulary at all, which is why the classifier leads with it.
CUTOFF_MARKS = "-–—"

#: Hesitation noise, normalized, listed token by token because classification is
#: per-token — "you know" contributes `you` and `know`.
#:
#: Used only to decide what is **not** a false start (`false_start_tokens`), never to
#: decide what is a disfluency. That one-directional use is what makes a fixed list
#: tolerable in a module whose whole argument is that real transcripts are not
#: enumerable: an unlisted filler is charged exactly what every disfluency was charged
#: before this weighting existed, so the list being incomplete costs nothing, while the
#: list being wrong could only under-charge.
#:
#: `disfluency.py` injects from a palette that has to stay inside this set — pinned by
#: a test, so a filler added to the injector cannot start reading as an abandoned
#: phrase and silently triple its own weight.
HESITATIONS = frozenset(
    """
    um uh uhh er erm ah oh hmm mm mhm huh uhhuh
    like just you know i mean sort kind of basically actually literally
    right yeah yep ok okay so well lets see and but
    """.split()
)

#: What one word of an uncorrected false start costs, in errors. 1.0 restores plain WER.
#:
#: The problem this fixes: every leftover token cost exactly one error, so a surviving
#: "um" and a surviving abandoned clause were worth the same to the search. Measured
#: over 400 `nyra` rows: 15.0% of the input words have to be deleted, and only 3.7% of
#: them — a quarter of that surplus — are abandoned spans, concentrated in 20% of the
#: rows at a mean of 4.1 words each. So an instruction that removed every filler and
#: not one false start gave up about 0.04 of content score, where the gap between rival
#: instructions is nearer 0.01. More was buyable by polishing filler removal than by
#: learning the hard case, and the search bought it.
#:
#: The hard case is also the one that shows. A leftover "um" reads as a typo; "we
#: wouldn't ha-" left standing in front of "we wouldn't have them" pastes a sentence the
#: user never said.
#:
#: **Why 5 and not more.** Swept over 1200 `nyra` rows, against hypotheses that leave a
#: fixed share of each abandoned span dangling in front of an otherwise perfect cleanup.
#: The number that matters is how far apart the metric can hold a good cleanup and a
#: nearly-good one — the gap between 0% and 25% residue, since that is the region a
#: search actually operates in:
#:
#:     weight     0%     25%     50%     75%    100%    gap 0->25%
#:          3  1.000   0.778   0.579   0.435   0.284         0.222
#:          5  1.000   0.650   0.361   0.160  -0.026         0.350
#:          8  1.000   0.487   0.114  -0.128  -0.330         0.513
#:
#: The gradient keeps growing, so that column alone argues for any weight at all. The
#: other end is what bounds it: `from_error_rate` decays past WER 1 rather than clipping,
#: and that decay flattens, so a row whose uncorrected span alone clears WER 2 stops being
#: rankable against its neighbours. At 3 that is 16 of the 232 false-start rows, at 5 it is
#: 45, at 8 it is 81 — and the 10th-to-90th-percentile spread across those rows peaks at 5
#: (1.403) before falling back to 1.281 at 8. Five buys the most resolution the metric can
#: hold: the strongest gradient where candidates differ, with total failure landing near
#: zero ("as bad as saying nothing") rather than deep in the flat tail.
#:
#: Corpus-level, the no-cleanup floor moves from 0.797 unweighted to 0.658 at 5.
#:
#: Charged per abandoned **word**, so a three-word abandoned span costs nine errors
#: rather than three. Deliberate — the length of what was left in is the size of the
#: mistake. Note that raising this changes what every axis reports, so numbers either
#: side of a change to it are not comparable.
FALSE_START_WEIGHT = 5.0

#: What one word of a dictated punctuation command left in the output costs, in errors.
#: 1.0 charges it like any other surplus word.
#:
#: Its own weight because it is its own failure, and because the number it had before was
#: an accident. A command left in is charged twice by plain WER already — a substitution
#: for the mark that never appeared, plus an insertion for the word that did — so it came
#: to 2 on the format axis without anyone deciding 2. That is only twice what *dropping*
#: the command costs, and dropping it is the cosmetic version: `children` where the
#: reference wants `children.` is a missing mark, while `children period` pastes into the
#: user's document a word they never meant to write. Those are not two grades of the same
#: mistake.
#:
#: The argument for a weight is `FALSE_START_WEIGHT`'s, almost verbatim: a leftover "um"
#: reads as a typo, and a leftover "period" reads as the software malfunctioning. The
#: argument for it being *lower* than the false-start weight is that an abandoned span is
#: usually several words (4.1 on nyra) and fabricates a clause the speaker never said,
#: while a command is one or two words and merely fails to disappear.
#:
#: **Why 3.** Swept over 1114 command-carrying `nyra` rows (2.36 commands each), against
#: hypotheses that leave a fixed share of each row's commands unconverted in front of an
#: otherwise perfect cleanup. Format axis, since that is what a spoken run selects on:
#:
#:     weight     0%    25%    50%    75%   100%   gap 0->25%   unrankable
#:          1  1.000  0.944  0.842  0.725  0.677        0.056       1/1114
#:          2  1.000  0.920  0.770  0.594  0.520        0.080       3/1114
#:          3  1.000  0.896  0.697  0.464  0.370        0.104      11/1114
#:          4  1.000  0.873  0.626  0.339  0.231        0.127      25/1114
#:          5  1.000  0.849  0.556  0.221  0.104        0.151      51/1114
#:          8  1.000  0.778  0.365 -0.079 -0.196        0.222     225/1114
#:
#: The gradient in the region candidates actually differ in (0% to 25% residue) argues
#: for any weight at all — 3 nearly doubles the unweighted 0.056 — and keeps growing, so
#: it does not pick a number. Two things bound it.
#:
#: **`FALSE_START_WEIGHT` is the ceiling, and it binds at 4, not 5.** On the format axis a
#: leftover command is already charged the mark's substitution as well as the word's
#: insertion, so its total is this weight plus one: 4 at a weight of 3, sitting between a
#: leftover filler (1) and a leftover abandoned word (5). At a weight of 4 it ties the
#: abandoned word, which is the wrong ordering — an abandoned span fabricates a clause the
#: speaker never said, while a command is one stray word that failed to disappear.
#:
#: **The tail bounds it too.** `from_error_rate` decays past WER 1 rather than clipping,
#: and that decay flattens, so a row whose residue alone clears WER 2 stops being rankable
#: against its neighbours. That is 1.0% of rows at 3, 4.6% at 5, and 20% at 8.
#:
#: It also lands 4x what *dropping* the command costs, which is the distinction the old
#: incidental 2 could barely make: `children` for `children.` is a missing mark, and
#: `children period` is a word in the user's document they never meant to write.
#:
#: Charged per command **word**, so "question mark" costs twice "comma" — the same
#: per-word convention as the false-start surcharge, and for the same reason: two spurious
#: words in the user's text is twice the mess of one.
#:
#: A token already charged as an abandoned false start is not charged again here. Rule 1
#: of `_is_abandoned` fires on a cut-off word regardless of vocabulary, so a command word
#: caught inside an abandoned run is charged at the higher weight and excluded from this
#: one.
COMMAND_WEIGHT = 3.0


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
    #: Where each `inserted` token sat in the hypothesis, same order and length.
    #: Only the false-start classifier needs positions, but they have to come from
    #: here: recovering them afterwards would mean a second, differently-tie-broken
    #: alignment, and the two could disagree about which of "really really" was the
    #: extra one.
    inserted_positions: tuple[int, ...] = ()

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
    inserted_positions: list[int] = []

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
            inserted_positions.append(j - 1)
            j -= 1

    return Alignment(
        reference_length=rows,
        # The backtrace walks right-to-left; reverse so the diffs read in
        # sentence order when they land in feedback text.
        substituted=tuple(reversed(substituted)),
        deleted=tuple(reversed(deleted)),
        inserted=tuple(reversed(inserted)),
        inserted_positions=tuple(reversed(inserted_positions)),
    )


def _is_cut_off(token: str) -> bool:
    """`th-`, `ha-`, `store—`: a word broken off mid-utterance, dash and all.

    Read off the raw token, before normalization strips the very mark being looked
    for. Trailing sentence punctuation is stripped first because a transcriber writes
    the cut-off inside the clause it interrupts — `ha-,` is the common shape.
    """
    stem = token.rstrip(",.;:!?\"')]}")
    return len(stem) > 1 and stem[-1] in CUTOFF_MARKS


def _runs(positions: list[int]) -> list[list[int]]:
    """Group sorted indices into consecutive runs — one abandoned span per run."""
    grouped: list[list[int]] = []
    for position in positions:
        if grouped and position == grouped[-1][-1] + 1:
            grouped[-1].append(position)
        else:
            grouped.append([position])
    return grouped


def _echoes_its_neighbour(run: list[int], spoken: list[tuple[str, str]]) -> bool:
    """Is this run a verbatim repeat of the span beside it?

    "it was it was really bad" is a stammer, not an abandoned thought: the speaker
    said the same words again rather than changing course. Same-length window on
    either side, because which copy of a duplicated span the alignment charges as the
    insertion is a tie-break, not a fact about the speech.
    """
    words = [word for _, word in (spoken[index] for index in run)]
    size = len(words)
    start = run[0]
    before = [word for _, word in spoken[start - size : start]] if start >= size else []
    after = [word for _, word in spoken[run[-1] + 1 : run[-1] + 1 + size]]
    return words in (before, after)


def _is_abandoned(
    run: list[int], spoken: list[tuple[str, str]], command_words: frozenset[str] = frozenset()
) -> bool:
    """Whether one surplus run is an abandoned span rather than a stumble.

    Two ways to qualify, in order of how much they can be trusted:

    1. It contains a **cut-off word** (`CUTOFF_MARKS`). Unambiguous, and annotated by
       the corpus itself rather than inferred here.
    2. It is **two or more non-hesitation words** that aren't an echo of the span
       beside them — a phrase the speaker started and replaced. One word is not
       enough: a lone surplus content word is a repetition or a slip, and charging
       triple for it would sweep in most of what the old flat weight already handled.

    `command_words` is vocabulary the *caller's corpus* planted as dictation commands,
    counted alongside `HESITATIONS` in rule 2. Without it the classifier reads "question
    mark" — two non-hesitation words that echo nothing — as an abandoned phrase and
    charges it `FALSE_START_WEIGHT` per word, making a leftover "question mark" ten errors
    and a leftover "period" one, an asymmetry nobody chose. Those words are charged
    `COMMAND_WEIGHT` instead. It defaults to empty and is passed only by an utterance that
    planted commands, so every number measured before it existed is unchanged.
    """
    if any(_is_cut_off(spoken[index][0]) for index in run):
        return True
    words = [spoken[index][1] for index in run]
    if sum(word not in HESITATIONS and word not in command_words for word in words) < 2:
        return False
    return not _echoes_its_neighbour(run, spoken)


def false_start_tokens(
    disfluent: str, reference: str, command_words: frozenset[str] = frozenset()
) -> tuple[str, ...]:
    """The words of `disfluent` the speaker abandoned, normalized, in order.

    A multiset, not a set: "we wouldn't ha-, we wouldn't have them" abandons three
    words and leaving all three in is three times the mistake of leaving one.

    Derived from the pair rather than annotated, since no corpus here labels
    reparanda: align the spoken side against the intended one, and whatever the
    speaker said that the reference does not contain is surplus. `_is_abandoned` then
    decides which of those surplus runs were abandoned phrases rather than hesitation.
    Runs, not tokens, because abandonment is a property of the span — "we wouldn't" is
    only recognizable as abandoned by the `ha-` sitting in front of it. A hedge caught
    inside such a run ("um we walked-") is charged with it, which is right: the whole
    region was abandoned, and the model has to delete all of it or none.

    `command_words` passes through to `_is_abandoned` — see there for why a corpus that
    plants dictation commands has to name them.
    """
    spoken = [(raw, word) for raw in disfluent.split() if (word := normalize_text(raw))]
    alignment = align(normalize(reference), [word for _, word in spoken])
    abandoned: list[str] = []
    for run in _runs(sorted(set(alignment.inserted_positions))):
        if _is_abandoned(run, spoken, command_words):
            abandoned.extend(spoken[index][1] for index in run)
    return tuple(abandoned)


def uncorrected_false_starts(
    disfluent: str,
    reference: str,
    alignment: Alignment,
    command_words: frozenset[str] = frozenset(),
) -> tuple[str, ...]:
    """Abandoned words the cleanup left in — the multiset `FALSE_START_WEIGHT` charges.

    The intersection of what the speaker abandoned with what the hypothesis added over
    the reference, so a cleanup is charged for the abandoned words it kept and not for
    the ones it removed. `alignment` is the content-axis diff of reference against
    hypothesis; both sides are already normalized there, which is what lets the raw
    `store—` in the input match the `store` the model echoed back.
    """
    spoken = false_start_tokens(disfluent, reference, command_words)
    left_in = Counter(alignment.inserted) & Counter(spoken)
    return tuple(sorted(left_in.elements()))


def uncorrected_commands(
    alignment: Alignment, command_words: frozenset[str], abandoned: tuple[str, ...] = ()
) -> tuple[str, ...]:
    """Dictated command words the cleanup left in — what `COMMAND_WEIGHT` charges.

    A multiset read straight off the diff: every word the hypothesis added over the
    reference that the input contained as a command. No membership test beyond that is
    needed, because `command_words` is already scoped to this one pair — the corpus
    planted those words in this input, so an added occurrence of one is a command that
    failed to disappear.

    `abandoned` is subtracted so no token is charged twice. `_is_abandoned`'s first rule
    fires on a cut-off word whatever the vocabulary, so a command word caught inside an
    abandoned run is charged at `FALSE_START_WEIGHT` and must not also be charged here.
    The higher weight wins, which is right: that whole region has to go.
    """
    if not command_words:
        return ()
    left_in = Counter(word for word in alignment.inserted if word in command_words)
    return tuple(sorted((left_in - Counter(abandoned)).elements()))


@dataclass(frozen=True)
class Score:
    """One cleanup attempt, scored on both axes."""

    content: float
    format: float
    content_alignment: Alignment
    format_alignment: Alignment
    #: Abandoned words the cleanup left in, already priced into both axes above.
    #: Kept alongside them so `feedback` can name the failure instead of the reflector
    #: having to guess which of its leftovers cost triple.
    uncorrected_false_starts: tuple[str, ...] = ()
    #: Dictated command words the cleanup left in, priced at `COMMAND_WEIGHT`. Same
    #: reason as above: a reflector told only "left disfluencies in: comma" cannot tell
    #: that this leftover is neither a disfluency nor charged like one.
    uncorrected_commands: tuple[str, ...] = ()

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


def _surcharged(alignment: Alignment, extra_errors: float) -> float:
    """`alignment`'s error rate with extra errors added over the same denominator.

    The denominator stays the reference length, so the surcharge is in the same unit
    as every other error and `from_error_rate` handles the result unchanged — a
    candidate that leaves enough abandoned text in can push past WER 1 and land in the
    decaying tail, which is the correct place for "worse than saying nothing".
    """
    if not extra_errors or alignment.reference_length == 0:
        return alignment.error_rate
    return alignment.error_rate + extra_errors / alignment.reference_length


def score(
    reference: str,
    hypothesis: str,
    disfluent: str | None = None,
    command_words: frozenset[str] = frozenset(),
) -> Score:
    """Score a cleanup against its reference on both axes — see `from_error_rate`.

    `disfluent` is what the model was given. Pass it and leftover false starts are
    charged `FALSE_START_WEIGHT`; omit it and the result is plain WER, because whether
    a leftover word was abandoned or merely hesitated over is a fact about the input
    and cannot be recovered from the other two strings. Every caller in the harness
    passes it — `corpus.Utterance.scored` exists so the pair's two sides travel
    together rather than being remembered at each call site.

    The same surcharge lands on both axes. A word left in is a word left in whichever
    way you tokenize, and exempting the formatting axis would quietly dilute the
    weighting by 30% under the default `blend`.

    `command_words` names the dictation commands the corpus planted in `disfluent`. They
    are exempt from the false-start classifier and charged `COMMAND_WEIGHT` when left in —
    see both constants. Empty by default, so nothing that does not pass it changes.
    """
    content_alignment = align(normalize(reference), normalize(hypothesis))
    format_alignment = align(surface(reference), surface(hypothesis))
    left_in = (
        uncorrected_false_starts(disfluent, reference, content_alignment, command_words)
        if disfluent
        else ()
    )
    commands = uncorrected_commands(content_alignment, command_words, left_in)
    surcharge = (FALSE_START_WEIGHT - 1.0) * len(left_in) + (COMMAND_WEIGHT - 1.0) * len(commands)
    return Score(
        content=from_error_rate(_surcharged(content_alignment, surcharge)),
        format=from_error_rate(_surcharged(format_alignment, surcharge)),
        content_alignment=content_alignment,
        format_alignment=format_alignment,
        uncorrected_false_starts=left_in,
        uncorrected_commands=commands,
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

    Abandoned spans are reported apart from ordinary leftovers, and told what they
    cost. They are the failure the score weights heaviest (`FALSE_START_WEIGHT`),
    and a reflector shown "left disfluencies in: um, ha-, we, wouldn't" has no way to
    tell which four of those words moved the number. Dictated commands
    (`COMMAND_WEIGHT`) are split out for the same reason, and because calling one a
    disfluency points the reflector at the wrong rule: "comma" is not a hesitation the
    speaker made, it is an instruction they gave.

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

    # Abandoned words are pulled out of the leftovers before they are counted as
    # ordinary ones, so the reflector reads two distinct failures rather than one list
    # in which the expensive words are indistinguishable from the cheap ones.
    abandoned = Counter(scored.uncorrected_false_starts)
    commands = Counter(scored.uncorrected_commands)
    leftover: list[str] = []
    invented: list[str] = []
    for word in content.inserted:
        if abandoned[word]:
            abandoned[word] -= 1
        elif commands[word]:
            commands[word] -= 1
        elif word in spoken:
            leftover.append(word)
        else:
            invented.append(word)

    if scored.uncorrected_false_starts:
        kept = ", ".join(sorted(set(scored.uncorrected_false_starts)))
        notes.append(
            f"left an abandoned false start in the output: {kept} — the speaker broke off and "
            "started the phrase again, so those words are not part of what they meant to write, "
            f"and each one is scored as {FALSE_START_WEIGHT:g} errors rather than one. This is "
            "the costliest mistake on this task"
        )
    if scored.uncorrected_commands:
        kept = ", ".join(sorted(set(scored.uncorrected_commands)))
        notes.append(
            f"left dictated punctuation commands in the output as words: {kept} — each is "
            f"scored as {COMMAND_WEIGHT:g} errors rather than one, because it reaches the "
            "reader as a word the speaker never meant to write"
        )
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
        f"Score {scored.value(axis):.2f} ({axis}). The cleanup {detail}. Reference: {reference!r}."
    )
