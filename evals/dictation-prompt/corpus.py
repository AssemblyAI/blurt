"""Where the eval's (disfluent input, clean target) pairs come from.

Two kinds of source, both yielding the same `Utterance`:

**Paired** — a dataset that already ships both sides. These are the ones to
prefer: the disfluencies are the ones real speakers produced, not the ones we
thought to write down.

- `nyra` (default) — `nyralabs/disfluency_speech_english`, a repackaging of
  `amaai-lab/DisfluencySpeech`: ~5k utterances from one speaker re-recording ~10
  hours of real Switchboard telephone conversations, whose disfluencies trained
  annotators marked by hand under the LDC stylebook. It ships them as
  `verbatim_transcript` / `intended_transcript` with the casing repaired, which is
  why the formatting axis is live here.

  It costs some fidelity for that: it retains repetitions the hand annotation
  marked as reparanda, and rewrites the verbatim side into its own conventions
  (`[UH]`, `[laughter]`, `th*`), which `_detag_nyra` has to undo.

  `amaai-lab/DisfluencySpeech` itself was registered here and has been removed as a
  duplicate — same recordings, same annotations, reached through unrepaired casing
  that made its targets unreliable enough to disable the formatting axis. Re-add it
  if the repackaging is ever suspected of costing accuracy, since it is the only
  way to check nyra against the unmodified pairs.

`google-research-datasets/disfl_qa` was registered here and has been removed. Its
floor looked like headroom — 0.435 against Switchboard's 0.834 — but it is a QA
*robustness* benchmark, not a cleanup corpus: annotators inserted a contextual
disfluency into SQuAD questions "using the paragraph as a source of distractors",
so the thing to delete is a semantic decoy rather than a speaker's slip. It asks
for 31% of words to be deleted with **none** of them fillers, and 11% of its
targets contain words absent from the input. Tuning a cleanup instruction there
teaches it to discard content, which is what `CleanupInstruction` forbids.

**Reference-only** — clean transcripts that the injector turns into pairs
(`disfluency.py`). Only `builtin` now, a small bundled sample for the offline path.

`google/fleurs` was registered here and has been removed. It is read speech with a
single clean transcript and no disfluent side at all, so every disfluency it scored
was one this repo wrote: the injector's filler list doubled as the answer key, which
measures whether an instruction removes the disfluencies we thought of rather than
the ones speakers produce. `nyra` does the same job with disfluencies trained
annotators marked by hand. What went with it is the severity dial and punctuation
*restoration* as a task, both of which now exist only on `builtin`.

`--jsonl` reads a local file, accepting either shape: objects with both
`disfluent` and `reference` are used as-is, anything with only a reference goes
through the injector.

Dataset rows arrive over the Hugging Face datasets-server rows API, which returns
audio columns as URLs rather than bytes — a few hundred transcripts cost a few
hundred kilobytes and no extra dependency. A `--loader datasets` alternative that
went through the library existed for gated sets and was removed: nothing registered
here is gated, and it was the only thing pulling `datasets` into the import path.
"""

from __future__ import annotations

import json
import os
import pathlib
import random
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field, replace

import disfluency
import metrics
import spoken_punctuation

ROWS_API = "https://datasets-server.huggingface.co/rows"

# Utterance-length window, in words of the reference. The floor drops examples too
# short for a disfluency to matter; the ceiling drops material that stops looking
# like one dictated burst and would let a few long outliers dominate the mean.
MIN_WORDS = 3
MAX_WORDS = 60

# Reference-only sources feed the injector, which needs room to work and — for the
# formatting axis to mean anything — a reference that is actually punctuated.
MIN_WORDS_FOR_INJECTION = 8

_TAG = re.compile(r"\[([A-Za-z_]+)\]")
_CUTOFF = re.compile(r"\b([A-Za-z]+)\*")
# The two bracketed tags that stand for words the speaker said; every other tag is
# a non-speech event (laughter, breath, cough) that a transcriber would not emit.
_SPOKEN_TAGS = {"uh": "uh", "um": "um"}


def _detag_nyra(text: str) -> str:
    """Rewrite the corpus's annotation conventions as ordinary transcript text.

    `[UH] ... th* ... [laughter]` becomes `uh ... th- ...`, so the model sees what
    a speech-to-text service would actually hand it rather than a labelling scheme.
    Applied to both sides: the target should not contain tags either.
    """
    text = _TAG.sub(lambda m: _SPOKEN_TAGS.get(m.group(1).lower(), ""), text)
    text = _CUTOFF.sub(lambda m: f"{m.group(1)}-", text)
    return re.sub(r"\s+", " ", text).strip()


@dataclass(frozen=True)
class Source:
    """One place pairs can come from, and what the corpus it yields supports."""

    key: str
    dataset: str
    split: str
    config: str | None = None
    # Paired sources name both columns; reference-only sources name just the one.
    input_field: str | None = None
    target_field: str = ""
    detag: Callable[[str], str] | None = None
    # False when the reference side carries no capitalization or punctuation, so
    # the formatting axis would score noise.
    formatting_is_measurable: bool = True
    note: str = ""

    @property
    def is_paired(self) -> bool:
        return self.input_field is not None

    @property
    def fields(self) -> tuple[str, ...]:
        return (self.input_field, self.target_field) if self.is_paired else (self.target_field,)


SOURCES: dict[str, Source] = {
    "nyra": Source(
        key="nyra",
        dataset="nyralabs/disfluency_speech_english",
        split="test",
        input_field="verbatim_transcript",
        target_field="intended_transcript",
        detag=_detag_nyra,
        note="the same corpus recased and repunctuated, at the cost of some fidelity",
    ),
}

# Stand-in corpus for `--source builtin`. Written for this repo (not drawn from any
# dataset) so the offline path carries no third-party licensing — which is also what
# makes it the only corpus here that can be *committed*: `data/spoken-punctuation.jsonl`
# is generated from these sentences, so a frozen dataset can live in the tree without
# redistributing LDC-licensed Switchboard transcripts. See `--dump-corpus`.
#
# The first twelve are the original offline sample and are kept first and unchanged, so
# a test or a `--limit 12` smoke run sees exactly the rows it always did. Everything
# after them exists to give the punctuation task something to bite on, which the
# original dozen could not:
#
# - **Internal commas and terminal marks** on most rows, since `spoken_punctuation`
#   speaks only marks the reference licenses. A corpus of bare declaratives licenses one
#   period each and nothing else.
# - **Questions and exclamations**, so `?` and `!` fire at all. `nyra` supplies 43
#   question marks per 400 rows and no exclamation points whatsoever.
# - **Colons and semicolons**, which `nyra` never supplies, so those entries in
#   `spoken_punctuation.SPOKEN_FORMS` are exercised by something.
# - **Literal-use traps** — references that use "period", "comma", "question mark",
#   "colon", "dash" or "all caps" as ordinary content. These are the blind spot `nyra`
#   cannot cover (~0-1% of its rows), and they compose with the injector into the
#   sharpest case on the task: "one grace period comma so plan accordingly" has to come
#   back as "one grace period, so plan accordingly", keeping the word and obeying the
#   command that follows it. An instruction that pattern-matches the vocabulary rather
#   than reading the sentence loses a content word here, which the score charges.
BUILTIN_SAMPLE: tuple[str, ...] = (
    "The build failed because the signing certificate expired over the weekend.",
    "Can you send me the latest numbers before the review meeting tomorrow morning?",
    "I think we should ship the fix behind a flag and watch the crash rate for a day.",
    "The microphone permission dialog never appears when the app runs from a temporary directory.",
    "Let's move the retrospective to Thursday so everyone in Berlin can attend.",
    "She pointed out that the transcript is already punctuated when it comes back from the service.",
    "We measured about a hundred and seventy milliseconds of connection setup on a cold start.",
    "The overlay should stay on screen until the paste actually lands in the target application.",
    "Nobody has looked at the notarization logs since the last release went out.",
    "It turns out the regression was introduced by the change to the clipboard restore path.",
    "Please double check the sample rate before you send the audio to the transcription endpoint.",
    "The design review is blocked on whether we keep the menu bar item at all.",
    # Prose with internal commas, which is what licenses anything other than a period.
    "If the upload stalls, retry it once, and then fall back to the smaller chunk size.",
    "We shipped the change on Tuesday, and by Thursday the error rate had halved.",
    "The onboarding flow works, but the second screen still asks for a permission we never use.",
    "Before you merge, rebase on main, run the whole suite, and check the coverage gate.",
    "I read the incident report, and the root cause was a stale cache in the edge layer.",
    "Once the lease expires, the worker stops accepting jobs, which is what we wanted.",
    "The vendor confirmed the outage, apologised, and promised a postmortem by Friday.",
    "Send the draft to Priya, loop in the design team, and we can review it together.",
    "When the mic is muted, the waveform freezes, and users read that as a crash.",
    "The migration touched four tables, two indexes, and one view nobody remembered.",
    "After the retry budget runs out, the request fails, and the overlay says try again.",
    "We looked at three vendors, and only one of them will sign a data processing agreement.",
    "The cache warms in about a minute, so the first few requests are always slower.",
    "If you cannot reproduce it locally, attach the sysdiagnose, and I will look tonight.",
    "The estimate assumed two engineers, and we have one, so the date needs to move.",
    "Their API returns a 202, then polls, then hands back a URL that expires in an hour.",
    "I moved the standup to nine, cancelled the Thursday sync, and blocked out Friday afternoon.",
    "The feature is behind a flag, off by default, and only enabled for the internal team.",
    # Questions, so the question-mark command has something to attach to.
    "Did anyone check whether the new entitlement survives a clean install?",
    "Should we hold the release until the notarization queue clears, or ship it now?",
    "Can you remind me what the retry budget is on the streaming endpoint?",
    "Do you know why the waveform stops animating when the window loses focus?",
    "Is there a reason we still ship the old audio unit alongside the new one?",
    "What happens to a partial transcript if the socket closes before the final message?",
    "Would it be easier to gate this on the account tier instead of a flag?",
    "Have we ever measured how long the first paste takes on a cold launch?",
    "Are the crash reports symbolicated, or do I need to upload the archive myself?",
    "Who owns the dashboard now that the analytics team has been folded into platform?",
    # Exclamations, which no corpus here otherwise supplies.
    "That fixed it, and the latency dropped by half!",
    "Please do not ship this on a Friday afternoon again!",
    "The whole suite passed on the first try for once!",
    "Watch out, the staging database is still pointed at production!",
    # Colons and semicolons, so those commands are exercised by something.
    "Here is the plan: land the fix, cut a build, and hand it to QA tomorrow.",
    "Two things are still open: the entitlement review and the App Store description.",
    "The cause was simple: we were reading the sample rate from the wrong device.",
    "It builds cleanly on my machine; it fails on the runner every single time.",
    "Ship the smaller change first; the refactor can wait until after the release.",
    "The tradeoff is straightforward: more accuracy for about eighty milliseconds of latency.",
    "Keep the interface as it is; only the storage layer needs to change.",
    "One caveat: the migration is not reversible once the first write lands.",
    # Literal-use traps. The reference uses a command word as content, so an instruction
    # that converts on sight loses a real word here.
    "We only support one grace period, so plan accordingly before the trial ends.",
    "Add a comma after the second clause and the sentence reads much better.",
    "Every question mark in that survey was ambiguous, so we rewrote the whole form.",
    "The billing period rolls over at midnight UTC, not at midnight local time.",
    "Put a colon after the heading and leave the rest of the line alone.",
    "She used a full stop where the style guide clearly asks for a semicolon.",
    "The legal team wants the warning in all caps, which our design system forbids.",
    "That exclamation point in the release notes reads as sarcasm, so please remove it.",
    "There is a dash missing from the second bullet on the pricing page.",
    "I said period, and it typed the word instead of the punctuation mark.",
    "The Cretaceous period ended with an impact, which is roughly how the demo went.",
    "Use a semicolon there; a comma is not strong enough to join those two clauses.",
    # More ordinary dictation, to keep the traps from dominating a small corpus.
    "Remind me to follow up with the accessibility team about the focus ring.",
    "The transcript came back empty, which usually means the audio was all silence.",
    "I will draft the announcement tonight and send it round for comments in the morning.",
    "We should probably stop supporting the beta channel now that nobody is on it.",
    "The keyboard shortcut conflicts with the system dictation shortcut on a fresh install.",
    "Let me know if the new model handles background noise any better than the old one.",
    "Nothing in the logs explains why the first request after a sleep always times out.",
    "The onboarding video is four minutes long and most people quit after thirty seconds.",
    "I would rather fix the flake than mark the test as skipped and forget about it.",
    "Our smallest customer files more bug reports than the other twenty combined.",
    "The release notes need a line about the new permission before we can publish.",
    "Check whether the trial expiry is stored in the keychain or in user defaults.",
    # Multi-sentence rows. Every other sentence here ends at the terminal mark, so the
    # word *after* a spoken period was never exercised: 0 of 61 terminal marks on the
    # generated corpus had a following word, and restoring its capital is half of what
    # a period command asks for. On `nyra` that case is 26% of terminal marks, because
    # Switchboard utterances run to several sentences. These put it back — including the
    # two shapes the injector treats specially, a proper noun after the mark and the
    # pronoun "I", which keep their capitals where an ordinary word loses it.
    "The build is green. Ship it before the release window closes tonight.",
    "I read the whole thread. Nobody actually answered the question that was asked.",
    "We tried that last quarter. It made the cold start worse, so we reverted it.",
    "The fix is small. The test that proves it is not, and that is the whole delay.",
    "Priya reviewed the diff. She wants the retry logic split into its own function.",
    "London is three hours ahead. Move the sync earlier or half the team misses it.",
    "Something changed upstream. I cannot reproduce yesterday's numbers at all now.",
    "Do not merge this yet. The staging run has not finished and I want to see it.",
    "It works on my machine. It does not work on the runner, which is the usual story.",
    "Check the entitlement first. Everything else follows from whether that survived.",
    "That was the last blocker! We can cut the build as soon as CI comes back green.",
    "Are we still shipping Thursday? The notarization queue was two hours this morning.",
    "The overlay flickers once on launch. Nobody has been able to catch it on video.",
    "Thursday is a holiday in Berlin. Let us push the retrospective out by a week.",
    "I filed it as a P2. Honestly it should be a P1 given how many users hit it.",
)


# Stand-in corpus for `--source punctuation`, and the base for the committed
# punctuation dataset. Written for this repo, like `BUILTIN_SAMPLE`, so a dataset
# generated from it can live in the tree.
#
# Separate from `BUILTIN_SAMPLE` because the two corpora are asked different questions and
# the material for one is wrong for the other. A disfluency smoke corpus wants plain
# declaratives with room to inject hesitation into. A punctuation corpus wants **internal
# marks**, because `spoken_punctuation.inject` will not speak the last token: a dictated
# "period" on the final word asks for a mark any instruction would produce unprompted, so
# obeying it and ignoring it score the same. Of what `BUILTIN_SAMPLE` licenses, 55% is
# exactly that, and 37 of its 91 rows have nothing else.
#
# So every row here carries at least one mark that is not utterance-final, and most carry
# several. Three kinds, and `spoken_punctuation.effect` prices them:
#
# - a **mid-utterance terminal mark** is worth 2 — the mark, and the capital behind it;
# - an **internal comma, colon or semicolon** is worth 1, at a placement inside the clause
#   that default punctuation does not reliably guess;
# - **ALL CAPS** is worth one per word, and is the only command nothing produces by
#   accident.
#
# The last group are literal-use traps, and they still carry internal marks so they test
# both things at once: "one grace period comma so plan accordingly" has to come back with
# the noun kept and the command obeyed.
PUNCTUATION_SAMPLE: tuple[str, ...] = (
    # Two sentences: the internal mark forces a split and the capital behind it.
    "The build is green. Ship it before the release window closes tonight.",
    "I read the whole thread. Nobody actually answered the question that was asked.",
    "We tried that last quarter. It made the cold start worse, so we reverted it.",
    "The fix is small. The test that proves it is not, and that is the whole delay.",
    "Priya reviewed the diff. She wants the retry logic split into its own function.",
    "London is three hours ahead. Move the sync earlier or half the team misses it.",
    "Something changed upstream. I cannot reproduce yesterday's numbers at all now.",
    "Do not merge this yet. The staging run has not finished and I want to see it.",
    "It works on my machine. It does not work on the runner, which is the usual story.",
    "Check the entitlement first. Everything else follows from whether that survived.",
    "That was the last blocker! We can cut the build as soon as CI comes back green.",
    "Are we still shipping Thursday? The notarization queue was two hours this morning.",
    "The overlay flickers once on launch. Nobody has caught it on video yet.",
    "Thursday is a holiday in Berlin. Let us push the retrospective out by a week.",
    "I filed it as a P2. Honestly it should be a P1 given how many users hit it.",
    "The vendor confirmed the outage. They promised a postmortem by Friday afternoon.",
    "Stop the rollout. The error rate tripled in the last twenty minutes of traffic.",
    "Nobody owns this dashboard. That is why it has been broken since February.",
    "The estimate assumed two engineers. We have one, so the date has to move out.",
    "I will draft the announcement tonight. Send me any corrections before nine.",
    # Comma-rich, so the placement inside the clause is what is being asked for.
    "If the upload stalls, retry it once, and then fall back to the smaller chunk size.",
    "We shipped the change on Tuesday, and by Thursday the error rate had halved.",
    "The onboarding flow works, but the second screen asks for a permission we never use.",
    "Before you merge, rebase on main, run the whole suite, and check the coverage gate.",
    "I read the incident report, and the root cause was a stale cache in the edge layer.",
    "Once the lease expires, the worker stops accepting jobs, which is what we wanted.",
    "Send the draft to Priya, loop in the design team, and we can review it together.",
    "When the mic is muted, the waveform freezes, and users read that as a crash.",
    "The migration touched four tables, two indexes, and one view nobody remembered.",
    "After the retry budget runs out, the request fails, and the overlay says try again.",
    "We looked at three vendors, and only one will sign a data processing agreement.",
    "The cache warms in about a minute, so the first few requests are always slower.",
    "If you cannot reproduce it locally, attach the sysdiagnose, and I will look tonight.",
    "Their API returns a 202, then polls, then hands back a URL that expires in an hour.",
    "I moved the standup to nine, cancelled the Thursday sync, and blocked out Friday.",
    "The feature is behind a flag, off by default, and enabled only for the internal team.",
    "Given the timing, the risk, and how little we know, I would rather wait a week.",
    "The parser is fine, the writer is fine, and the thing between them loses a byte.",
    "Whatever we do, do it before the freeze, because after that nothing lands.",
    "She asked for the numbers, the caveats, and a recommendation on one page.",
    # A mark mid-utterance and a question or exclamation, so those commands fire too.
    "The queue drained overnight. Are we confident it will hold under Monday traffic?",
    "I looked at the trace. Why is the second request slower than the first one?",
    "We fixed the leak. Did anyone check whether the fix survives a clean install?",
    "The demo went well. Can you send the recording to the whole team this afternoon?",
    "It finally reproduced! The trick was launching from a read-only directory.",
    "That is the third regression this week! We need the gate back on before Friday.",
    "The numbers came in. Honestly, they are better than anything we projected.",
    "Everything is symbolicated now. You should be able to read the crash directly.",
    # Colons and semicolons, internal, so those commands are exercised at all.
    "Here is the plan: land the fix, cut a build, and hand it to QA tomorrow morning.",
    "Two things are still open: the entitlement review and the store description.",
    "The cause was simple: we were reading the sample rate from the wrong device.",
    "It builds cleanly on my machine; it fails on the runner every single time.",
    "Ship the smaller change first; the refactor can wait until after the release.",
    "The tradeoff is straightforward: more accuracy for eighty milliseconds of latency.",
    "Keep the interface as it is; only the storage layer actually needs to change.",
    "One caveat: the migration is not reversible once the first write has landed.",
    "Three people asked for this: two customers and one person on the support rota.",
    "The rule is simple; if the test is flaky, fix it or delete it the same day.",
    # Content worth shouting, so the casing command has somewhere natural to land.
    "This is urgent, and the deadline is Friday, not the following Wednesday.",
    "Do not deploy this today. The database migration has not been reviewed yet.",
    "The answer is no, and it will stay no until the security review is finished.",
    "Never commit the signing key. Rotate it immediately if it ever reaches a log.",
    "Everything downstream depends on this table, so treat the schema as frozen.",
    "The important part is the ordering, not the individual steps in the pipeline.",
    "Read the whole thread before replying, because the decision changed twice.",
    "That number is wrong, and it has been wrong in every deck since November.",
    "Only the release manager can approve this, and only after the gate is green.",
    "The critical path is the notarization, not the build, so start it early.",
    # Literal-use traps, each with an internal mark so both things are tested at once.
    "We only support one grace period, so plan accordingly before the trial ends.",
    "Add a comma after the second clause, and the sentence reads much better.",
    "Every question mark in that survey was ambiguous, so we rewrote the whole form.",
    "The billing period rolls over at midnight UTC, not at midnight local time.",
    "Put a colon after the heading, and leave the rest of the line exactly as it is.",
    "She used a full stop where the style guide asks for a semicolon, which is minor.",
    "The legal team wants that warning in all caps, which our design system forbids.",
    "That exclamation point reads as sarcasm, so please take it out of the release notes.",
    "There is a dash missing from the second bullet, and a typo in the third one.",
    "I said period, and it typed the word instead of the punctuation mark I wanted.",
    "The Cretaceous period ended with an impact, which is roughly how the demo went.",
    "Use a semicolon there; a comma is not strong enough to join those two clauses.",
)


@dataclass(frozen=True)
class Utterance:
    """One eval example: what the model is given, and what it should produce."""

    reference: str
    disfluent: str
    # Injector operators, empty for a real paired corpus — nobody annotated those.
    operations: tuple[str, ...] = field(default=())
    #: Spoken punctuation commands planted in `disfluent` by
    #: `spoken_punctuation.inject`, empty unless `--spoken-punctuation` is on. Kept on
    #: the utterance because the only thing that can say whether a command was obeyed
    #: is the record of what was planted — WER sees a missing comma and a missing word
    #: as the same kind of error, and cannot see a *casing* command at all on the
    #: content axis. Travels with the pair for the same reason both sides do.
    commands: tuple[spoken_punctuation.Command, ...] = field(default=())
    #: True when the input side came from the source rather than from an injector here —
    #: a paired dataset column, or a `--jsonl` row that carried a `disfluent` key.
    #:
    #: Recorded rather than inferred from `is_disfluent`, which was the proxy before and
    #: is wrong in exactly the case a dumped corpus produces: a row whose input happens
    #: to equal its reference (no command drawn, no disfluency drawn) reads as "needs
    #: injecting", so re-loading a dumped file would silently hand that row a *different*
    #: input than the file records. The documented contract is "objects with both
    #: disfluent and reference are used as-is", and this is what makes it true.
    input_supplied: bool = False

    @property
    def is_disfluent(self) -> bool:
        """False when input and target already match — a don't-over-edit example."""
        return metrics.normalize(self.disfluent) != metrics.normalize(self.reference)

    def scored(self, hypothesis: str) -> metrics.Score:
        """Score a cleanup of this utterance, both sides of the pair supplied.

        Here rather than at each call site because `metrics.score` needs the input as
        well as the target — a leftover word is only recognizable as an abandoned false
        start, and chargeable at `metrics.FALSE_START_WEIGHT`, by looking at what was
        spoken. Omitting it is silent: the score comes back as plain WER and looks
        entirely reasonable. An utterance holds both sides already, so let it be the
        thing that remembers.
        """
        return metrics.score(self.reference, hypothesis, self.disfluent, self.command_words)

    @property
    def command_words(self) -> frozenset[str]:
        """The dictation commands planted in `disfluent`, as normalized words.

        Empty for every corpus that plants none, so this changes no number measured
        before it existed. Scoring needs it for two things, both consequences of the same
        fact — that these words are commands rather than speech. `metrics._is_abandoned`
        must not read "question mark" as an abandoned phrase, which is exactly its shape:
        two non-hesitation words echoing nothing. And `metrics.COMMAND_WEIGHT` charges
        one left in the output more than an ordinary surplus word, because it reaches the
        user's document as a word they never meant to write.

        Bare words, not positions, so on a row that uses one as content — "Stop the
        rollout" against a spoken "full stop" — the exemption covers the speaker's own
        noun too. It costs almost nothing: the exemption only bites on words the
        *hypothesis added*, so a cleanup that keeps the content word correctly, or drops
        it, is unaffected either way, and only one that duplicates it is over-charged.
        Positions would fix it and would have to survive the round trip through
        `--dump-corpus` to be worth having.
        """
        return frozenset(word for command in self.commands for word in command.spoken_words)


@dataclass(frozen=True)
class Corpus:
    """Loaded pairs plus where they came from, for the results file."""

    utterances: tuple[Utterance, ...]
    source: str
    detail: dict[str, object]
    formatting_is_measurable: bool = True

    def __len__(self) -> int:
        return len(self.utterances)

    @property
    def commands_planted(self) -> int:
        """Spoken-punctuation commands across the whole corpus.

        Read instead of `--spoken-punctuation` wherever the run has to decide whether it
        is posing the punctuation task — which axis to select on, which candidates to
        score, whether to print the command table. A corpus loaded from a
        `--dump-corpus` file via `--jsonl` carries the commands and not the flag, and
        keying on the flag meant that dataset silently selected on `blend` and reported no
        command outcomes: the same corpus, scored two different ways depending on how it
        was reached.
        """
        return sum(len(u.commands) for u in self.utterances)

    @property
    def has_commands(self) -> bool:
        return self.commands_planted > 0

    @property
    def disfluent_fraction(self) -> float:
        """Share of examples whose input actually differs from its target."""
        if not self.utterances:
            return 0.0
        return sum(u.is_disfluent for u in self.utterances) / len(self.utterances)


def _tidy(text: object) -> str:
    return " ".join(text.split()) if isinstance(text, str) else ""


def _usable_reference(text: str, *, for_injection: bool) -> bool:
    """Is this reference worth keeping as a target?"""
    words = len(text.split())
    floor = MIN_WORDS_FOR_INJECTION if for_injection else MIN_WORDS
    if not floor <= words <= MAX_WORDS:
        return False
    # A reference with no terminal punctuation is a truncated or normalized
    # transcript; injecting into it and then scoring punctuation restoration
    # against it would penalize a correct cleanup.
    return not for_injection or text[-1] in ".?!"


def _collect(utterances, limit: int, *, for_injection: bool) -> list[Utterance]:
    """Filter, de-duplicate by reference, and cap — the one copy of that policy.

    Consumes lazily, so a paging loader stops fetching as soon as `limit` usable
    pairs have been found.

    Takes whole `Utterance`s rather than `(disfluent, reference)` pairs so that a source
    can carry more than the two strings through this filter: a `--jsonl` row restores the
    commands and operators a `--dump-corpus` run recorded, and dropping them here would
    make a saved dataset score differently from the corpus it was saved from.
    """
    seen: set[str] = set()
    kept: list[Utterance] = []
    for utterance in utterances:
        reference, disfluent = _tidy(utterance.reference), _tidy(utterance.disfluent)
        if not reference or not disfluent:
            continue
        if not _usable_reference(reference, for_injection=for_injection):
            continue
        if reference in seen:
            continue
        seen.add(reference)
        kept.append(replace(utterance, reference=reference, disfluent=disfluent))
        if len(kept) >= limit:
            break
    return kept


def _field(row: dict, name: str, where: str) -> object:
    """Read a column, naming what was actually available when it's missing."""
    if name not in row:
        available = ", ".join(sorted(row)) or "(none)"
        raise RuntimeError(f"field {name!r} not in {where}; available: {available}")
    return row[name]


def hf_token() -> str | None:
    """The Hugging Face token, however the user happens to have supplied it.

    Anonymous requests to the datasets-server are rate limited, so a long run —
    or a few short ones in a row — will start getting 429s. Authenticating lifts
    that.

    `hf auth login` (and the older `huggingface-cli login`) writes a token to a
    file rather than exporting a variable, so checking only the environment would
    ignore the very thing someone reaches for when told to "log in". Resolution
    order matches the `huggingface_hub` library's own, so both routes work and an
    explicit env var still wins.
    """
    for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        token = os.environ.get(name)
        if token and token.strip():
            return token.strip()

    home = os.environ.get("HF_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache", "huggingface"
    )
    for path in (os.environ.get("HF_TOKEN_PATH"), os.path.join(home, "token")):
        if not path:
            continue
        try:
            token = pathlib.Path(path).read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if token:
            return token
    return None


#: Attempts per page against a 429, and the base of the backoff between them.
#:
#: The rows API rate-limits by volume, not just by anonymity: a 4000-row load is ~40
#: pages, and a token raises the ceiling without removing it. Failing the whole load on
#: one 429 wastes the pages already fetched and, worse, fails *before* the first model
#: call — so a run set up to take an hour dies at second zero. Bounded, because a rate
#: limit that has not lifted in a minute of waiting is a quota rather than a burst, and
#: the error already says what to do about it.
_RATE_LIMIT_ATTEMPTS = 5
_RATE_LIMIT_BACKOFF = 4.0


def _rows_via_api(source: Source, limit: int):
    """Page the datasets-server rows API, yielding raw row dicts."""
    token = hf_token()
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    offset, page = 0, 100
    # Filtering discards a fraction of rows, so allow several pages' worth of
    # headroom before giving up rather than returning a short corpus silently.
    while offset < max(limit * 10, 1000):
        query = urllib.parse.urlencode(
            {
                "dataset": source.dataset,
                "config": source.config or "default",
                "split": source.split,
                "offset": offset,
                "length": page,
            }
        )
        payload = _fetch_page(f"{ROWS_API}?{query}", headers, source, token)

        rows = payload.get("rows", [])
        if not rows:
            return
        for entry in rows:
            yield entry.get("row", {})
        offset += page


def _fetch_page(url: str, headers: dict, source: Source, token: str | None) -> dict:
    """One page of rows, waiting out a rate limit rather than failing the load.

    Retries only 429. Every other HTTP status is a fact about the request or the
    dataset that waiting will not change, and the 500s the server intermittently
    returns are worth surfacing rather than papering over — a load that silently took
    four minutes to work around a broken upstream is harder to diagnose than one that
    said so.
    """
    for attempt in range(1, _RATE_LIMIT_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(  # noqa: S310 — fixed https endpoint
                urllib.request.Request(url, headers=headers), timeout=60
            ) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")[:400]
            if error.code != 429:
                raise RuntimeError(
                    f"datasets-server returned HTTP {error.code} for {source.dataset}: {body}"
                ) from error
            if attempt == _RATE_LIMIT_ATTEMPTS:
                advice = (
                    "Authenticating raises the limit: run `hf auth login`, or set HF_TOKEN to a "
                    "read token from https://huggingface.co/settings/tokens"
                    if not token
                    else "A token is already in use, so this is the authenticated ceiling — wait "
                    "a few minutes, or lower --limit"
                )
                raise RuntimeError(
                    f"rate limited by {ROWS_API} while reading {source.dataset}, still after "
                    f"{_RATE_LIMIT_ATTEMPTS} attempts. {advice}."
                ) from error
            delay = _RATE_LIMIT_BACKOFF * 2 ** (attempt - 1)
            print(f"  rate limited; retrying in {delay:.0f}s ({attempt}/{_RATE_LIMIT_ATTEMPTS})")
            time.sleep(delay)
        except urllib.error.URLError as error:
            raise RuntimeError(
                f"could not reach {ROWS_API} ({error.reason}). "
                "Use --jsonl or --source builtin to work offline."
            ) from error
    raise AssertionError("unreachable: the loop either returns or raises")


def _utterances_from_rows(rows, source: Source, where: str):
    """Project raw dataset rows into utterances, de-tagging where needed."""
    detag = source.detag or (lambda text: text)
    for row in rows:
        reference = detag(_tidy(_field(row, source.target_field, where)))
        if source.is_paired:
            yield Utterance(
                reference=reference,
                disfluent=detag(_tidy(_field(row, str(source.input_field), where))),
                input_supplied=True,
            )
        else:
            # Reference-only: the injector fills the input side in `load`.
            yield Utterance(reference=reference, disfluent=reference)


def _utterances_from_jsonl(path: str):
    """Read a local file: pairs, bare references, or a `--dump-corpus` dataset.

    A dumped row round-trips exactly — its `commands` and `operations` come back, so the
    saved dataset scores identically to the corpus it was saved from and `load` knows not
    to inject over it. A hand-written row with only a reference still goes through the
    injector, and a bare line is read as a reference.
    """
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            if not line.startswith("{"):
                yield Utterance(reference=line, disfluent=line)
                continue
            row = json.loads(line)
            reference = row.get("reference") or row.get("text") or row.get("transcript") or ""
            yield Utterance(
                reference=reference,
                disfluent=row.get("disfluent") or reference,
                operations=tuple(row.get("operations", ())),
                commands=tuple(
                    spoken_punctuation.Command.from_json(c) for c in row.get("commands", ())
                ),
                input_supplied="disfluent" in row,
            )


def dump_jsonl(loaded: Corpus, path: str) -> int:
    """Write a loaded corpus as JSONL, exactly as `_utterances_from_jsonl` reads it back.

    Why a dataset is worth freezing at all: the corpus this harness scores against is
    assembled at load time from a dataset download, a seeded disfluency injector and a
    seeded punctuation injector. That is reproducible in principle and unreviewable in
    practice — nobody reads a generator to find out whether the examples are any good, and
    a change to an injector silently changes what every past number was measured on. A
    file in the tree is diffable.

    What can be committed is limited by licensing, not by size. `--source builtin` is
    written for this repo (see `BUILTIN_SAMPLE`), so a dataset generated from it carries
    no third-party terms; `nyra` derives from LDC-licensed Switchboard transcripts, so
    dump it locally and leave it out of the tree.
    """
    lines = []
    for utterance in loaded.utterances:
        row: dict[str, object] = {
            "reference": utterance.reference,
            "disfluent": utterance.disfluent,
        }
        if utterance.operations:
            row["operations"] = list(utterance.operations)
        if utterance.commands:
            row["commands"] = [command.to_json() for command in utterance.commands]
        lines.append(json.dumps(row, ensure_ascii=False))
    pathlib.Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(lines)


def load(
    *,
    source: str = "nyra",
    limit: int = 120,
    split: str | None = None,
    jsonl: str | None = None,
    seed: int = 7,
    severity: float = 0.35,
    strip_formatting: bool = False,
    spoken_punctuation_rate: float = 0.0,
    spoken_caps_rate: float = 0.25,
    punctuation_only: bool = False,
) -> Corpus:
    """Load up to `limit` pairs, injecting disfluencies for reference-only sources."""
    if jsonl:
        rows = _utterances_from_jsonl(jsonl)
        spec, detail, formatted = None, {"path": jsonl}, True
    elif source == "builtin":
        rows = (Utterance(reference=text, disfluent=text) for text in BUILTIN_SAMPLE)
        spec, formatted = None, True
        detail = {"note": "bundled sample; no dataset was downloaded"}
    elif source == "punctuation":
        rows = (Utterance(reference=text, disfluent=text) for text in PUNCTUATION_SAMPLE)
        spec, formatted = None, True
        detail = {"note": "bundled punctuation sample; no dataset was downloaded"}
    elif source in SOURCES:
        spec = SOURCES[source]
        # Each source defaults to its held-out split, which is small (250 rows for
        # nyra). A run large enough to separate close candidates has
        # to reach into `train` — harmless here, since nothing is fine-tuned and
        # the harness makes its own train/dev/test partition of whatever it loads.
        if split:
            spec = replace(spec, split=split)
        where = f"{spec.dataset}/{spec.split}"
        rows = _utterances_from_rows(_rows_via_api(spec, limit), spec, where)
        formatted = spec.formatting_is_measurable
        detail = {
            "dataset": spec.dataset,
            "config": spec.config,
            "split": spec.split,
            "fields": list(spec.fields),
            "note": spec.note,
        }
    else:
        raise ValueError(
            f"unknown source {source!r}; expected builtin or one of {', '.join(SOURCES)}"
        )

    # A reference-only source needs the injector to produce an input side, and
    # needs a reference long and well-punctuated enough to inject into. A jsonl
    # file is the user's own text, so it is filtered leniently either way.
    # `punctuation_only` makes any source reference-only: the target becomes the input
    # base and the verbatim side is discarded. That is the whole point of the mode — the
    # input must differ from the target by nothing but the spoken commands, so a score
    # cannot be moved by disfluency removal. On `nyra` it means scoring against the
    # intended side, which is real conversational English and no longer a paired corpus.
    reference_only = spec is None or not spec.is_paired or punctuation_only
    utterances = _collect(rows, limit, for_injection=reference_only and jsonl is None)
    if punctuation_only:
        utterances = [
            replace(u, disfluent=u.reference, input_supplied=False, operations=())
            for u in utterances
        ]

    if reference_only and not punctuation_only:
        injected: list[Utterance] = []
        for index, utterance in enumerate(utterances):
            # A jsonl row that already carried a disfluent side keeps it — read off
            # `input_supplied` rather than `is_disfluent`, so a dumped row whose input
            # happens to equal its reference is not quietly re-injected into something
            # else. Per-example seeds (rather than one shared generator) keep an
            # utterance's disfluencies stable when the corpus around it changes, so
            # re-running with a larger --limit doesn't reshuffle what you already
            # looked at.
            if utterance.input_supplied:
                injected.append(utterance)
                continue
            disfluent, operations = disfluency.inject(
                utterance.reference,
                seed=seed + index,
                severity=severity,
                strip_formatting=strip_formatting,
            )
            injected.append(
                Utterance(reference=utterance.reference, disfluent=disfluent, operations=operations)
            )
        utterances = injected
        detail |= {"injected": True, "severity": severity, "strip_formatting": strip_formatting}

    # Spoken punctuation goes on last, over whatever the input side already is — real
    # annotated disfluencies from a paired source, or the injector's. That ordering is
    # the point: the task under test is a dictation user saying "comma" *while* also
    # hesitating, not either in isolation, and layering it keeps the disfluencies the
    # ones a corpus actually recorded rather than ones this repo wrote. Per-example
    # seeds for the same reason the disfluency injector uses them — a row's commands
    # stay put when the corpus around it grows.
    if spoken_punctuation_rate:
        spoken: list[Utterance] = []
        for index, utterance in enumerate(utterances):
            # A row that already carries commands has been through this injector — a
            # `--dump-corpus` dataset read back with the flag still set. Injecting again
            # would speak marks that are no longer there and score the result against a
            # reference whose ALL CAPS run has been uppercased twice.
            if utterance.commands:
                spoken.append(utterance)
                continue
            reference, disfluent, commands = spoken_punctuation.inject(
                utterance.reference,
                utterance.disfluent,
                seed=seed + index,
                rate=spoken_punctuation_rate,
                caps_rate=spoken_caps_rate,
                require=punctuation_only,
            )
            # A row the injector could not plant anything in measures nothing on a corpus
            # whose only subject is commands, and dilutes every mean it appears in. It
            # happens when the reference's only mark is its last one, which `inject`
            # refuses to speak.
            if punctuation_only and not commands:
                continue
            spoken.append(
                replace(
                    utterance,
                    reference=reference,
                    disfluent=disfluent,
                    operations=utterance.operations + tuple(c.label for c in commands),
                    commands=commands,
                )
            )
        utterances = spoken
        detail |= {
            "spoken_punctuation_rate": spoken_punctuation_rate,
            "spoken_caps_rate": spoken_caps_rate,
            "punctuation_only": punctuation_only,
            "commands_per_row": sum(len(u.commands) for u in utterances) / len(utterances)
            if utterances
            else 0.0,
        }

    if not utterances:
        raise RuntimeError(f"no usable pairs from {source!r} (needs {MIN_WORDS}-{MAX_WORDS} words)")

    return Corpus(
        utterances=tuple(utterances),
        source="jsonl" if jsonl else source,
        detail=detail,
        formatting_is_measurable=formatted,
    )


def slice_size(value: float, total: int) -> int:
    """A share of the corpus when below 1, an absolute row count at 1 or above.

    The `train_test_split` convention, adopted here because the three slices have
    very different costs and so should not be coupled to `--limit` together. Train
    rows are effectively free — GEPA draws a fixed number of fixed-size reflection
    minibatches however large the trainset is — while every dev row is paid for
    roughly eight times over (each candidate, the seed, the re-score) plus GEPA's
    full evals, and every test row twice. Absolute sizes let `--limit` grow the free
    slice without dragging the expensive two along behind it.

    Not clamped here — `split` reconciles the two slices against the corpus together,
    since clamping them independently is what strands one of them at zero.
    """
    return int(total * value) if value < 1 else int(value)


def carve_validation(train: list[Utterance], size: float) -> tuple[list, list]:
    """Take the optimizer's valset off the front of train, returning (validation, train).

    Here rather than in the CLI so the tests exercise the carve the run performs
    instead of a copy of it — reversing the slice order in one and not the other would
    otherwise go unnoticed.
    """
    count = slice_size(size, len(train))
    return train[:count], train[count:]


def split(utterances: list[Utterance], seed: int, dev_size: float, test_size: float):
    """Shuffle once with a fixed seed, then slice into train / dev / test.

    Shuffling matters because dataset splits are often ordered by speaker or
    source document; slicing an unshuffled corpus would put systematically
    different material in train and test.

    `dev_size` and `test_size` are each a fraction or an absolute count — see
    `slice_size`. When the two together ask for more than the corpus holds, both are
    scaled down in proportion rather than being satisfied in order: taking `test`
    first and giving `dev` the remainder leaves dev empty, which reads as a corpus
    problem when it is really an arithmetic one. Scaling keeps the smoke path honest
    — `--source builtin` is 12 rows against defaults sized for 2000. Train can still
    end up empty, and deliberately so: `--optimizer none` needs only dev and test,
    while a search that genuinely has no trainset should fail loudly rather than run
    on a slice quietly borrowed from somewhere else.
    """
    shuffled = list(utterances)
    random.Random(seed).shuffle(shuffled)
    total = len(shuffled)
    n_dev, n_test = slice_size(dev_size, total), slice_size(test_size, total)
    if n_dev + n_test > total:
        scale = total / (n_dev + n_test)
        n_dev, n_test = int(n_dev * scale), int(n_test * scale)
    return shuffled[n_test + n_dev :], shuffled[n_test : n_test + n_dev], shuffled[:n_test]


def false_start_fraction(utterances: list[Utterance]) -> float:
    """Share of pairs containing an abandoned span — what the surcharge can reach.

    Printed next to the floor because `metrics.FALSE_START_WEIGHT` only bites on these
    rows, so it is the number that says whether the weighting is shaping the search or
    is a rounding error on this corpus. Pure arithmetic; no model is involved.

    Reads each utterance's own `command_words`, so the figure printed is the figure
    charged. Without it a spoken-punctuation corpus reported 55% of rows carrying an
    abandoned span against 21% for the same rows unmodified — the difference being
    "question mark" counted as a false start in the report while `Utterance.scored`
    correctly declined to charge it.
    """
    if not utterances:
        return 0.0
    carrying = sum(
        bool(metrics.false_start_tokens(u.disfluent, u.reference, u.command_words))
        for u in utterances
    )
    return carrying / len(utterances)


def no_cleanup_floor(utterances: list[Utterance]) -> dict[str, float]:
    """Score of the corpus's disfluent side against its own target.

    Pure arithmetic — no request is made and no model is involved. It is the floor
    of the *metric*, not of the product: with enhanced transcripts on the service
    always applies some cleanup, so "paste the raw transcript" is not a state Blurt
    can actually be in. Read it as "how much work is there to do on this corpus",
    and treat a candidate scoring below it as actively harmful.
    """
    return metrics.mean([u.scored(u.disfluent) for u in utterances])
