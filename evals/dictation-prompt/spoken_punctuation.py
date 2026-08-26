"""Spoken punctuation injection — the "period, comma, question mark, ALL CAPS" task.

A dictation user who wants a comma often *says* "comma". The speech-to-text pass
transcribes that as the word, so the rewrite model is handed `send it today comma
then call me` and has to produce `send it today, then call me`. Nothing in
`disfluency.py` poses that: it only inserts hesitation, and every real paired corpus
in `corpus.py` has punctuation on both sides already.

This module layers the task onto a **real** pair rather than inventing one. It reads
the corpus's clean side to decide what a spoken mark would have to become, and then
speaks marks on the disfluent side only. So the target is still the corpus's own
target, the disfluencies are still the ones annotators marked by hand, and the only
synthetic part is the one thing being measured.

Two operators, and they are not the same kind of thing:

**Marks** (`period`, `comma`, `question mark`, …) are injected *subtractively on the
input side only*. A mark is spoken only when the reference **licenses** it — the same
word carries the same mark in the target — so the correct output is always the
reference exactly as it already stands, and the reference is never edited. A mark the
reference does not have is never spoken, because "say it and then delete it" is not a
rule any instruction should learn.

**ALL CAPS** is the exception, and the only place here that edits a target. You cannot
pose "uppercase this word" against a target with no uppercase in it, so the chosen run
is uppercased in the reference and prefixed with the command, lowercased, in the input.
That is a deliberate departure from `disfluency.py`'s additive-only invariant, and it
is confined to this one operator.

Both are visible almost entirely on the **format** axis. `metrics.normalize` casefolds
and strips punctuation, so a restored comma and a missed one are the same string to the
content axis; what content *does* see is the expensive failure — a command left in the
output as a literal word, which is an inserted token on both axes. That split is why
`--spoken-punctuation` selects on `format` by default: it is the axis that can see the
whole task, and it sees the leftover word too.

What this does **not** emulate is how a real speech-to-text pass renders a spoken
command in the first place. It probably applies its own casing and punctuation model on
top — returning something nearer `Children period.` than `children period` — and what it
does exactly is unknown without measuring the service. So the input here is the clean
form of the task: the command as a bare word, and no casing left to give it away. Read a
result as a ranking of instructions on that task, and `--verify-live` (README) as the
only thing that speaks to the real pipeline.

What the corpus cannot tell you: whether an instruction converts the word "period" when
the speaker meant the era. Only ~1% of `nyra` references use any command word literally
(the run reports the figure), so the score barely moves either way — the same shape of
blind spot as `candidates.REQUIRED_SAFEGUARDS`, and handled the same way, by putting the
clause in the instruction and saying here that nothing measures it.
"""

from __future__ import annotations

import random
from dataclasses import dataclass

import metrics

#: Marks a dictation user says out loud, and the words they say. Weighted because the
#: aliases are not equally common — "period" far outruns "full stop" in US dictation —
#: and present at all because an instruction tuned against a single spelling of each
#: command is an instruction that fails on the other one. The eval cannot see that
#: fragility if the injector only ever emits one form.
#:
#: `!`, `:` and `;` are here and effectively never fire on `nyra`: over 400 rows its
#: references carry 483 periods, 460 commas, 43 question marks and none of the other
#: three. They cost nothing to keep, they are what a `--jsonl` corpus of written prose
#: would exercise, and leaving them out would make the vocabulary a claim about
#: Switchboard rather than about dictation.
#:
#: Quotes, parentheses and dashes are deliberately absent. They are *paired* or
#: *span-scoped* commands ("open quote" … "close quote"), so injecting one means
#: deciding where the span ends — and Switchboard telephone transcripts contain almost
#: none of them, so the decision would be exercised by nothing.
SPOKEN_FORMS: dict[str, tuple[tuple[str, int], ...]] = {
    ".": (("period", 6), ("full stop", 1)),
    ",": (("comma", 1),),
    "?": (("question mark", 1),),
    "!": (("exclamation point", 2), ("exclamation mark", 1)),
    ":": (("colon", 1),),
    ";": (("semicolon", 1),),
}

#: Marks that end a sentence, so the word after them was capitalized by the transcriber
#: rather than by the speaker. Spoken, that capital has to go — see `inject`.
TERMINAL_MARKS = ".?!"

#: What the input says to uppercase a single word, and to open/close a longer run.
#: Both conventions are in real use; a run needs the bracketing form because "all caps"
#: alone says nothing about where the shouting stops.
CAPS_WORD = "all caps"
CAPS_ON = "caps on"
CAPS_OFF = "caps off"

#: Shortest word worth uppercasing. Below this the run is a function word, and "all caps
#: the" is not a thing anyone dictates — while `metrics.HESITATIONS` covers the openers
#: `candidates.PRIOR_WINNER` is told to delete aggressively, which would otherwise let a
#: caps command and a deletion rule fight over the same token.
MIN_CAPS_WORD = 4

#: Length of an uppercased run, and how often each length is chosen. Single words
#: dominate because that is what people dictate; the longer runs exist so the
#: bracketing form (`caps on` … `caps off`) is exercised at all.
CAPS_RUN_LENGTHS: tuple[tuple[int, int], ...] = ((1, 7), (2, 2), (3, 1))


@dataclass(frozen=True)
class Command:
    """One spoken instruction planted in the input, and how to tell if it landed.

    Carries the *anchor* — the word the mark attaches to — rather than only the mark,
    because "did this command get converted" is otherwise unanswerable: a hypothesis
    containing a comma somewhere says nothing about whether it is the comma that was
    asked for. With the anchor it is a local question about one word.
    """

    #: The words inserted into the input: `"comma"`, `"all caps"`, `"caps on"`.
    spoken: str
    #: The punctuation the target carries, or `""` for a casing command.
    mark: str
    #: `"mark"` or `"caps"` — which of the two operators produced this.
    kind: str
    #: Normalized word the mark attaches to; empty for a casing command.
    anchor: str = ""
    #: Normalized words a casing command uppercases; empty for a mark.
    words: tuple[str, ...] = ()
    #: The words that close a bracketed command (`caps off`), empty for every other kind.
    #:
    #: Held because the closing marker is part of the command's vocabulary and nothing
    #: else records it: `spoken` is only the opener. Left out, the word "off" sat in the
    #: input outside `command_words`, so a cleanup that left `caps off` standing was
    #: charged one ordinary insertion for it instead of `metrics.COMMAND_WEIGHT` — the
    #: same command, priced two ways depending on which half survived.
    closing: str = ""

    def to_json(self) -> dict:
        """The command as plain JSON, for `corpus.dump_jsonl`.

        Explicit rather than `dataclasses.asdict` so the on-disk shape is a decision
        rather than a consequence of field order, and a field added here has to be given
        a name on disk deliberately.
        """
        return {
            "spoken": self.spoken,
            "mark": self.mark,
            "kind": self.kind,
            "anchor": self.anchor,
            "words": list(self.words),
            "closing": self.closing,
        }

    @classmethod
    def from_json(cls, row: dict) -> Command:
        """Read one back. The round trip has to be exact — a dumped corpus that scores
        differently from the corpus it was dumped from is worse than no dumped corpus."""
        return cls(
            spoken=row["spoken"],
            mark=row.get("mark", ""),
            kind=row["kind"],
            anchor=row.get("anchor", ""),
            words=tuple(row.get("words", ())),
            closing=row.get("closing", ""),
        )

    @property
    def label(self) -> str:
        """Short name for `Utterance.operations` and the sample dump."""
        return f"spoken:{self.spoken.replace(' ', '-')}"

    @property
    def spoken_words(self) -> tuple[str, ...]:
        """The command's own words, normalized — what it added to the input.

        Handed to `metrics.score` as `not_abandoned` so the false-start classifier does
        not read "question mark" as an abandoned phrase and charge it five errors a word.
        See `metrics._is_abandoned`.
        """
        return tuple(metrics.normalize_text(f"{self.spoken} {self.closing}").split())

    @property
    def literal(self) -> tuple[str, ...]:
        """The normalized token run that means the command was left in as words.

        Anchored for a mark (`("today", "comma")`) and prefixed for a casing command
        (`("all", "caps", "urgent")`), so an instruction that happened to use the word
        elsewhere is not charged for it.
        """
        opener = tuple(metrics.normalize_text(self.spoken).split())
        return (self.anchor, *opener) if self.kind == "mark" else (*opener, *self.words)


def _tokens(text: str) -> list[tuple[int, str]]:
    """`[(index into text.split(), normalized word)]`, skipping bare punctuation.

    The corpus emits standalone `.` tokens (`"Yeah, I do . Yes uh"`), which normalize to
    the empty string. Dropping them here keeps every word-index computation below
    working on words, while the raw index stays available for editing the text.
    """
    return [(i, w) for i, raw in enumerate(text.split()) if (w := metrics.normalize_text(raw))]


def _split_mark(raw: str) -> tuple[str, str] | None:
    """`("today", ",")` for `"today,"`; None when there is no single trailing mark.

    Requires the mark to be the token's **last** character rather than searching a
    trailing run, so `it?"` is skipped rather than turned into `it question mark"`.
    Requires a non-empty stem for the same reason `_tokens` drops bare punctuation.
    """
    if len(raw) < 2 or raw[-1] not in SPOKEN_FORMS:
        return None
    stem = raw[:-1]
    return (stem, raw[-1]) if metrics.normalize_text(stem) else None


def licensed_marks(reference: str) -> set[tuple[str, str]]:
    """`(anchor, mark)` pairs the reference itself carries — the only ones speakable.

    This is the whole reason the reference never needs editing for a mark. `nyra`'s two
    sides are punctuated independently, so the disfluent side has marks the target does
    not: a comma sitting in front of a span the annotator deleted. Speaking *that* comma
    would ask the instruction to produce a mark and then have it scored as an error,
    teaching it that commands are sometimes to be ignored. Matching on `(anchor, mark)`
    keeps a spoken command one whose answer is already in the target.

    Word-and-mark rather than position, so nothing has to align the two sides. A
    repeated word can license a mark on a different copy of itself; that is a
    false *accept*, which costs nothing — the correct output still contains that
    mark on that word.
    """
    pairs: set[tuple[str, str]] = set()
    for raw in reference.split():
        if split := _split_mark(raw):
            pairs.add((metrics.normalize_text(split[0]), split[1]))
    return pairs


def _keeps_its_capital(raw: str) -> bool:
    """Whether this token's capital survives having its sentence's mark spoken.

    Only the pronoun *I*, and the reasoning is worth recording because a corpus-derived
    proper-noun rule stood here first and was removed as actively harmful.

    Speaking a terminal mark takes the following capital with it: the transcriber wrote
    `children. Schroeder's` and a speaker saying "period" produced no capital, so leaving
    one lets an instruction restore the period from the casing alone. The objection was
    that lowercasing `Schroeder's` charges a correct cleanup for damage the injector did —
    and measurement says it does not. That word is **sentence-initial in the reference by
    construction**, because a terminal mark is the only kind spoken here, so the required
    output is `Schroeder's` and the required action is the rule every candidate already
    states: capitalize the first word after a sentence-ending mark. Name or ordinary word,
    the task and the answer are identical.

    Protecting names, meanwhile, costs something real. Over 1000 `nyra` rows, 30% of the
    words following a licensed terminal mark appear capitalized mid-sentence somewhere in
    the corpus — so protecting them would hand the answer to a third of the commands, and
    a third chosen by which rows happen to mention a place name. Every spoken terminal
    mark now poses the same sub-task, which is the cleaner experiment.

    *I* is the exception because it is capitalized **everywhere**, mid-sentence included.
    Lowercasing it is the one case that makes the input a transcript no speech-to-text
    service would return — `politics full stop i'm not sure` — and it would show the model
    the same token cased two ways in one utterance. Matched on the raw token (`I`, `I'm`,
    `I'll`) rather than normalized, since `normalize_text` drops the apostrophe and `ill`
    is then indistinguishable from the adjective.
    """
    return raw == "I" or raw.startswith("I'")


def _occurrences(words: list[str], run: tuple[str, ...]) -> int:
    """How many times `run` appears contiguously in `words`."""
    return sum(1 for i in range(len(words) - len(run) + 1) if tuple(words[i : i + len(run)]) == run)


def _pick_caps_run(
    reference: str, disfluent: str, rng: random.Random
) -> tuple[tuple[int, ...], tuple[int, ...], tuple[str, ...]] | None:
    """A word run to uppercase, as `(reference indices, input indices, words)`.

    Three conditions, each closing off a way the example would be unanswerable:

    - **No punctuation on any token in the run.** `caps off` has to go after the run's
      last word, and a run ending in `important,` would put it after the comma. This
      also guarantees a caps run never overlaps a converted mark, so the two operators
      cannot collide.
    - **Long enough, and not a hesitation.** `all caps the` is not dictation, and
      `metrics.HESITATIONS` holds the openers `candidates.PRIOR_WINNER` deletes
      aggressively — a caps command on one of those pits two rules against each other.
    - **Exactly one occurrence in each side.** Uppercasing is applied by matching words,
      so a second copy makes "which one" undecidable for both the edit and the scoring.
    """
    reference_words, disfluent_words = _tokens(reference), _tokens(disfluent)
    plain = [w for _, w in disfluent_words]
    raw_reference = reference.split()
    lengths = [length for length, weight in CAPS_RUN_LENGTHS for _ in range(weight)]
    rng.shuffle(lengths)

    for length in lengths:
        starts = list(range(len(reference_words) - length + 1))
        rng.shuffle(starts)
        for start in starts:
            window = reference_words[start : start + length]
            run = tuple(w for _, w in window)
            if any(len(w) < MIN_CAPS_WORD or w in metrics.HESITATIONS for w in run):
                continue
            if any(raw_reference[i] != metrics.normalize_text(raw_reference[i]) for i, _ in window):
                continue
            if _occurrences([w for _, w in reference_words], run) != 1:
                continue
            if _occurrences(plain, run) != 1:
                continue
            first = next(
                i for i in range(len(plain) - length + 1) if tuple(plain[i : i + length]) == run
            )
            return (
                tuple(i for i, _ in window),
                tuple(disfluent_words[i][0] for i in range(first, first + length)),
                run,
            )
    return None


def _speak(mark: str, rng: random.Random) -> str:
    """One of `mark`'s spoken forms, drawn at its measured frequency."""
    forms, weights = zip(*SPOKEN_FORMS[mark], strict=True)
    return rng.choices(forms, weights=weights)[0]


def inject(
    reference: str,
    disfluent: str,
    *,
    seed: int,
    rate: float = 0.8,
    caps_rate: float = 0.25,
    require: bool = False,
) -> tuple[str, str, tuple[Command, ...]]:
    """Speak some of this pair's punctuation. Returns `(reference, input, commands)`.

    `rate` is the chance each **licensed** mark is spoken rather than left as a mark.
    Deliberately below 1: a corpus where every mark is a word teaches "there is no
    punctuation in the input", and the shortest instruction satisfying that is one that
    inserts marks by guesswork. Leaving some real marks in place keeps the instruction
    responsible for telling a command from a mark that is already correct.

    `caps_rate` is the chance the pair also gets one casing command — at most one,
    because a user shouting twice in one dictated sentence is not the common case and
    two commands in a 15-word utterance would make the operator most of the corpus.

    The **last token is never spoken**, and that exclusion is most of what makes a command
    a test of anything. A dictated "period" on the final word asks for a mark the model
    would produce unprompted — any instruction that says "restore punctuation" ends a
    sentence with a full stop — so obeying the command and ignoring it look identical, and
    the row scores the same either way. Those marks were 55% of what the bundled corpus
    licensed and 37% of nyra's. What survives is discriminative by construction: a
    mid-utterance terminal mark forces a sentence split *and* the following capital, an
    internal comma forces a placement inside the clause, and ALL CAPS forces uppercase,
    which nothing produces by default.

    `require` guarantees at least one command whenever the pair licenses one, by speaking
    a randomly chosen mark if the per-mark draws happened to select none. For a corpus
    whose whole subject is punctuation commands, a row carrying none is not a hard example
    — it is a row measuring nothing, diluting every mean it appears in. Off by default,
    because on a mixed corpus a row where the speaker punctuated normally is a legitimate
    negative: the instruction has to leave existing marks alone.

    The reference comes back **unchanged** unless a casing command was planted, which is
    the invariant that lets this run over a real paired corpus at all.
    """
    if not 0.0 <= rate <= 1.0:
        raise ValueError(f"rate must be in 0..1, got {rate}")
    if not 0.0 <= caps_rate <= 1.0:
        raise ValueError(f"caps_rate must be in 0..1, got {caps_rate}")

    rng = random.Random(seed)
    licensed = licensed_marks(reference)
    commands: list[Command] = []

    caps = _pick_caps_run(reference, disfluent, rng) if rng.random() < caps_rate else None
    caps_indices = frozenset(caps[1]) if caps else frozenset()

    # Which marks get spoken is settled before anything is emitted, because `require`
    # is a statement about the row as a whole: "none were selected" is only knowable
    # once every draw has been made.
    tokens = disfluent.split()
    convertible = [
        index
        for index, raw in enumerate(tokens)
        if index not in caps_indices
        and index != len(tokens) - 1
        and (split := _split_mark(raw))
        and (metrics.normalize_text(split[0]), split[1]) in licensed
    ]
    speaking = {index for index in convertible if rng.random() < rate}
    if require and convertible and not speaking:
        speaking = {rng.choice(convertible)}

    out: list[str] = []
    lowercase_next = False
    for index, raw in enumerate(tokens):
        if caps and index == caps[1][0]:
            bracketed = len(caps[2]) > 1
            out.append(CAPS_ON if bracketed else CAPS_WORD)
            commands.append(
                Command(
                    spoken=CAPS_ON if bracketed else CAPS_WORD,
                    mark="",
                    kind="caps",
                    words=caps[2],
                    closing=CAPS_OFF if bracketed else "",
                )
            )

        token = raw
        # A word the transcriber capitalized because a sentence started there, whose
        # mark is now a spoken word, loses the capital with it — restoring it is the task.
        # Only the pronoun "I" is exempt; see `_keeps_its_capital`.
        if lowercase_next and not _keeps_its_capital(token):
            token = token[:1].lower() + token[1:]
        lowercase_next = False

        # Inside a caps run the input carries the plain word; the reference carries the
        # shout. Applied before mark conversion, which `_pick_caps_run` has already
        # guaranteed cannot apply to these tokens.
        if index in caps_indices:
            out.append(token.lower())
        elif index in speaking:
            # `convertible` already checked the shape and the licence; the only thing
            # that can have changed `token` since is a leading capital.
            stem, mark = token[:-1], token[-1]
            spoken = _speak(mark, rng)
            out.extend((stem, spoken))
            commands.append(
                Command(
                    spoken=spoken,
                    mark=mark,
                    kind="mark",
                    anchor=metrics.normalize_text(stem),
                )
            )
            lowercase_next = mark in TERMINAL_MARKS
        else:
            out.append(token)

        if caps and index == caps[1][-1]:
            if len(caps[2]) > 1:
                out.append(CAPS_OFF)

    if caps:
        raw_reference = reference.split()
        for i in caps[0]:
            raw_reference[i] = raw_reference[i].upper()
        reference = " ".join(raw_reference)

    return reference, " ".join(out), tuple(commands)


#: How a planted command turned out in a cleanup. `literal` is the one that reaches the
#: user's document as visible nonsense, which is why it is counted apart from `missing`.
OUTCOMES = ("converted", "literal", "missing")


def _contains(words: list[str], run: tuple[str, ...]) -> bool:
    return _occurrences(words, run) > 0


def outcome(command: Command, hypothesis: str) -> str:
    """Whether `hypothesis` obeyed `command`, left it as words, or did neither.

    Answered against the command's anchor rather than by counting marks, so a cleanup
    that happens to punctuate elsewhere is not credited. `converted` accepts the mark on
    any copy of the anchor word — the same false accept `licensed_marks` tolerates, and
    for the same reason: on a repeated word the correct output carries the mark on that
    word either way.
    """
    plain = [w for _, w in _tokens(hypothesis)]
    if _contains(plain, command.literal):
        return "literal"

    if command.kind == "mark":
        for raw in hypothesis.split():
            # Trailing brackets and quotes sit outside the mark a speaker asked for.
            trimmed = raw.rstrip("\"')]}»")
            if trimmed.endswith(command.mark) and metrics.normalize_text(trimmed) == command.anchor:
                return "converted"
        return "missing"

    # Located as a contiguous run, the way `_pick_caps_run` chose it, and not by looking
    # each word up on its own. A word-keyed lookup took the *first* copy of each word,
    # which on "All the people signed confessions ... trying THESE PEOPLE now" found the
    # lowercase "people" from eight words earlier and reported a correctly shouted run as
    # missed. The run is unique in the reference by construction; it need not be in a
    # hypothesis, so any fully uppercased occurrence counts.
    raw = hypothesis.split()
    words = _tokens(hypothesis)
    length = len(command.words)
    for start in range(len(words) - length + 1):
        window = words[start : start + length]
        if tuple(word for _, word in window) != command.words:
            continue
        stems = [raw[index].strip(metrics.PUNCTUATION) for index, _ in window]
        if all(stem and stem.isupper() for stem in stems):
            return "converted"
    return "missing"


def undo(command: Command, reference: str) -> str:
    """The reference with this one command's effect taken back out.

    The mark it produced is removed and the capital that followed it lowered; a casing
    command's run is lowercased. What is left is the text a cleanup would emit if it had
    dropped the command silently — the honest comparison for asking what obeying it buys.
    """
    tokens = reference.split()
    if command.kind == "mark":
        for i, raw in enumerate(tokens):
            if raw.endswith(command.mark) and metrics.normalize_text(raw[:-1]) == command.anchor:
                tokens[i] = raw[:-1]
                if command.mark in TERMINAL_MARKS and i + 1 < len(tokens):
                    following = tokens[i + 1]
                    if not _keeps_its_capital(following):
                        tokens[i + 1] = following[:1].lower() + following[1:]
                break
        return " ".join(tokens)

    words = [w for _, w in _tokens(reference)]
    index = [i for i, _ in _tokens(reference)]
    span = len(command.words)
    for k in range(len(words) - span + 1):
        if tuple(words[k : k + span]) == command.words:
            for j in index[k : k + span]:
                tokens[j] = tokens[j].lower()
            break
    return " ".join(tokens)


def effect(command: Command, reference: str) -> int:
    """Format tokens that obeying `command` fixes — how much getting it right is worth.

    The marginal value of this one command: the reference against the reference with only
    this command's effect undone. Zero would mean the command is decoration — the same
    output scores the same whether the model understood it or not — and a corpus of those
    measures nothing however many rows it has.

    Nothing here can be zero, which is what the exclusions in `inject` buy: a
    mid-utterance terminal mark is worth 2 (the mark, and the capital behind it), an
    internal mark 1, and a casing command one per word. It is checked rather than filtered
    on for that reason — a zero means an invariant broke, not that the row is unusable.
    """
    diff = metrics.align(metrics.surface(reference), metrics.surface(undo(command, reference)))
    return diff.substitutions + diff.deletions + diff.insertions


def tally(pairs) -> dict[str, float]:
    """Command outcomes over `(commands, hypothesis)` pairs, as shares of the total.

    The number this whole module exists to produce. WER answers "how close is the text",
    which mixes the punctuation task into every other kind of error; this answers "of the
    commands actually planted, how many were obeyed" — and it can only be asked of a
    synthetic operator, because nothing else knows what was planted.

    `commands_total` rides along so a share of nothing is distinguishable from a share of
    everything: a corpus loaded without `--spoken-punctuation` reports zeros here and
    they mean "not asked", not "failed".
    """
    counts: dict[str, int] = dict.fromkeys(OUTCOMES, 0)
    for commands, hypothesis in pairs:
        for command in commands:
            counts[outcome(command, hypothesis)] += 1
    total = sum(counts.values())
    stats = {f"commands_{name}": (counts[name] / total if total else 0.0) for name in OUTCOMES}
    return stats | {"commands_total": float(total)}


def feedback_note(commands: tuple[Command, ...], hypothesis: str) -> str:
    """What the reflector needs to hear about the punctuation commands, or "".

    Separate from `metrics.feedback` because that module is the bottom of the dependency
    chain — it imports nothing else in the harness, so that nothing about how a corpus
    was built can leak into how it is scored. The command vocabulary is corpus
    construction, so it composes on top rather than moving down.

    Reports only the commands that were **dropped** — the ones whose words are gone and
    whose mark never appeared. A command left in as words is `metrics.feedback`'s to
    report, because that is where its weight lives (`metrics.COMMAND_WEIGHT`) and a
    failure named without its cost is half a fact. Saying it in both places was the first
    cut and it put the same complaint twice in every reflection prompt.

    Dropped commands are here because nothing in `metrics` can see them. A mark that was
    never produced is one substitution among many on the format axis and *nothing at all*
    on the content axis, and a missed ALL CAPS is invisible to content too — so without
    this the reflector reads "capitalization or punctuation differs from the reference"
    and has to guess that a command was the reason.
    """
    if not commands:
        return ""
    outcomes = [(command, outcome(command, hypothesis)) for command in commands]
    missing = [c for c, o in outcomes if o == "missing"]
    notes: list[str] = []
    if missing:
        asked = ", ".join(
            f"{c.spoken!r} -> {c.mark!r}" if c.kind == "mark" else f"{c.spoken!r} -> uppercase"
            for c in missing
        )
        notes.append(f"did not carry out spoken punctuation commands: {asked}")
    return f" It also {'; '.join(notes)}." if notes else ""


def phrases() -> tuple[tuple[str, ...], ...]:
    """Every command as a normalized word run — the vocabulary, in matchable form."""
    spoken = [form for forms in SPOKEN_FORMS.values() for form, _ in forms]
    spoken += [CAPS_WORD, CAPS_ON, CAPS_OFF]
    return tuple(tuple(metrics.normalize_text(form).split()) for form in spoken)


def literal_use_fraction(references) -> float:
    """Share of references that use a command *phrase* as ordinary content.

    Reported next to the floor because it bounds what the corpus can say about
    over-conversion. An instruction that rewrites "the Jurassic period was long" into
    "the Jurassic. was long" is only punished on these rows, and on `nyra` there are
    about 1% of them — so the clause forbidding it belongs in the instruction on the
    strength of the product, not on the strength of a score. Same shape of blind spot as
    `candidates.REQUIRED_SAFEGUARDS`, named rather than hidden.

    Whole phrases, contiguously, not the union of their words. Matching words was the
    first cut and it reported 22% of `nyra` rows as traps, which was ordinary English
    prose containing "all", "on", "off", "point" and "stop" — a diagnostic that says the
    blind spot is a fifth of the corpus when it is a fiftieth is worse than none, because
    it argues the gap has already been closed.
    """
    references = list(references)
    if not references:
        return 0.0
    vocabulary = phrases()
    return sum(
        any(_contains(metrics.normalize(text), phrase) for phrase in vocabulary)
        for text in references
    ) / len(references)
