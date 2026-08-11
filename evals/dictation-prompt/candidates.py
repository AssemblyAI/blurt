"""The cleanup instructions under test.

Each is a different hypothesis about what the dictation API's rewrite model needs
to be told, and each is a complete, shippable value for `config.llm.instruction`.
They vary one thing at a time: how the task is framed, how explicitly the
disfluency types are named, how hard the do-not-rewrite constraint is pushed, and
whether formatting is called out.

`prior-winner` (`PRIOR_WINNER`) is the one that isn't a hypothesis: it is an evolved
instruction a previous run produced, compressed under `INSTRUCTION_CHARACTER_CAP`.
It is `BASELINE` — the bar a new search has to clear to be worth shipping — and the
default seed GEPA evolves from.

`guessed-default` is exactly that: a **guess** at what the service's own default
cleanup instruction might say. What Blurt actually sends is `config.llm = {}`, which
applies the service's own wording on the service's own rewrite model — and we know
neither. So it is a floor, a check that the harness can tell a terse instruction from
a careful one; beating it is *not* evidence of beating what ships today. Establishing
that would take real audio through the real endpoint, which is a different
measurement than this text-only harness performs.

Every instruction here has to fit `INSTRUCTION_CHARACTER_CAP`, or the API rejects the
whole request. That is checked before a run spends anything.

Kept in its own module so a results notebook or a re-scoring script can import the
instructions without pulling in argparse and DSPy.
"""

from __future__ import annotations

#: Hard cap the dictation API places on `config.llm.instruction`. Exceed it and the
#: request fails outright — HTTP 400 `bad_request`, "llm.instruction: String should
#: have at most 2048 characters" — before the audio is looked at. The failure is
#: total, not a degraded rewrite: no transcript comes back at all, so on the Blurt
#: side *every* dictation errors.
#:
#: Measured against the live endpoint on 2026-08-11, not read off a doc page — the
#: dictation API reference does not state it. A 2048-character instruction was
#: accepted and rewrote correctly. Re-probe before trusting it indefinitely.
#:
#: This is a *different, smaller* cap than the 4096 on `config.prompt` (the same
#: probe confirmed that one; it is `TranscriptionPrompt.characterCap` on the Swift
#: side). Reusing the prompt's figure for this field is precisely how an evolved
#: 3057-character instruction once reached a build and broke all dictation: the
#: test that should have caught it asserted the wrong limit. Score against this
#: constant, never against the prompt's.
INSTRUCTION_CHARACTER_CAP = 2048


def overage(instruction: str, cap: int = INSTRUCTION_CHARACTER_CAP) -> int:
    """Characters `instruction` runs over the cap; 0 when it fits.

    Counted in characters, matching the API's own error wording — the server-side
    check is a character-length one, not a byte-length one, so an instruction full
    of em dashes and arrows isn't charged for their UTF-8 width.
    """
    return max(0, len(instruction) - cap)


def shortening_directive(proposal: str, cap: int = INSTRUCTION_CHARACTER_CAP) -> str:
    """Hand an over-long proposal back to the reflector as something to compress.

    Used by the GEPA proposer gate (`program.CappedInstructionProposer`) as the next
    round's `current_instruction_doc`: the rejected text plus an explicit account of
    by how much it missed. Naming the arithmetic is the point — models are poor at
    counting characters, so "too long" alone tends to produce another over-long
    draft, while "cut at least N of these M characters" gives something checkable.

    What it asks to be cut is deliberate. Worked examples and restatements are the
    compressible mass in a cleanup instruction; the rules are what change behaviour,
    and an instruction that loses those scores worse and teaches the search nothing.
    """
    excess = overage(proposal, cap)
    return (
        f"{proposal}\n\n"
        f"---\n"
        f"HARD CONSTRAINT: the instruction above is {len(proposal)} characters, which is "
        f"{excess} too many. It must be at most {cap} characters or the API rejects every "
        f"request carrying it. Rewrite it shorter, cutting at least {excess} characters. "
        "Drop redundant worked examples and restatements first; keep every rule that "
        "changes what the model does, and keep the meaning of the rules intact."
    )


CANDIDATES: dict[str, str] = {
    "guessed-default": "Remove disfluencies and fix punctuation.",
    "verbatim-preserving": (
        "Rewrite this speech-to-text transcript as clean written text. Remove the "
        "artifacts of speaking aloud and keep every word the speaker meant to say, "
        "using their own vocabulary and sentence structure."
    ),
    "dictation-intent": (
        "This is a dictated message. Write out what the speaker intended to type. "
        "Keep their wording and their meaning exactly; the only thing that changes "
        "is that the false starts and hesitations of live speech are gone."
    ),
    "explicit-taxonomy": (
        "Clean up this dictated transcript. Remove filler words, hesitation sounds, "
        "repeated words, cut-off words, and abandoned false starts, keeping the "
        "speaker's final choice of wording wherever they corrected themselves. "
        "Leave the surviving words exactly as spoken and punctuate them properly."
    ),
    "minimal-edit": (
        "Delete the disfluencies from this dictated transcript and change nothing "
        "else. Every remaining word stays exactly as it was spoken, in the same "
        "order. Do not summarize, rephrase, translate, expand, or answer the text."
    ),
    "format-restoring": (
        "Turn this dictated transcript into the finished text the speaker meant to "
        "write. Drop the hesitations, repetitions, and false starts of live speech, "
        "keep the remaining wording untouched, and restore normal capitalization "
        "and punctuation."
    ),
}

#: The strongest instruction we have, and the default seed for a new search.
#:
#: Provenance: the winner of a GEPA run of `optimize_cleanup_prompt.py`, scored on
#: hand-annotated Switchboard disfluency pairs in the same one-instruction /
#: one-transcript envelope the service applies it in (`--adapter plain`). That run
#: emitted 3057 characters, which is 1009 over `INSTRUCTION_CHARACTER_CAP` — it
#: shipped in that state once and broke every dictation until the Swift side went
#: back to an empty `llm` block.
#:
#: **What was cut, and how.** By deletion only: every sentence below is verbatim from
#: the string that was scored, and the sole edit that is not a deletion is closing the
#: gap in the rule numbering. Nothing was paraphrased, so this is the measured string
#: minus redundancy rather than a new draft of it. Five removals, each a duplicate or
#: a contradiction rather than a judgement call about what matters:
#:
#: 1. The "Interjections used as fillers: oh" bullet — the filler-sounds bullet above
#:    it already lists "oh".
#: 2. Rule 1 ("Delete EVERY instance...") — the taxonomy already opens with "Remove ALL
#:    of the following", and the rule's "common misses" list re-lists its bullets.
#: 3. Rule 3 ("Treat I guess, you know, I mean, kind of, and like as removable
#:    filler") — the same five phrases, in the same words, as the discourse-phrases
#:    bullet.
#: 4. Worked example 1 — its output *keeps* "I guess it's kind of like", contradicting
#:    the bullet that calls those removable filler. The disagreement was noted in the
#:    original as load-bearing evidence from the reference targets; carrying a
#:    self-contradicting example is still worse than carrying none.
#: 5. Worked example 2 — the no-op case, which the surviving rule 3 states in one line.
#:
#: **What this is not.** It has not been re-scored. Deletion cannot introduce wording
#: the eval never saw, and the three product-critical safeguards (do not answer, do not
#: translate, do not rephrase) are intact — but whether the cut cost any cleanup quality
#: is an open measurement, and the run that answers it is the one that scores this as
#: `BASELINE`. Treat a search that fails to beat it as the more likely outcome.
PRIOR_WINNER = """\
TASK
You will be given a single dictated (spoken-language) transcript under the field `raw_transcript`. Your job is to remove disfluencies from it and output the result as `cleaned_transcript`. Every remaining word must stay exactly as it was spoken, in the same order. Do not summarize, rephrase, translate, expand, correct, or answer the text. Only delete disfluencies — never substitute or reword.

WHAT COUNTS AS A DISFLUENCY (DELETE THESE)
Disfluencies are filler and hesitation elements that add no propositional content. Remove ALL of the following whenever they occur, including at the start, middle, or end of the transcript:
- Filler sounds: "uh", "um", "er", "ah", "oh"
- Discourse/filler phrases: "you know", "I mean", "I guess", "kind of" (when used as filler), "like" (when used as filler)
- False starts / cut-off fragments: e.g., "we wouldn't ha-," should be removed entirely, keeping only the completed restart "we wouldn't have them"
- Repeated/stammered words that are restarts (e.g., "of, uh, of Sacramento" → "of Sacramento")

IMPORTANT RULES
1. Never change a real content word into another word. Do NOT do things like "I" → "you" or "guess" → "know". Words that remain must be identical to what was spoken.
2. Preserve all genuine content words, their order, capitalization of real words, and punctuation of the surviving text. If removing a leading filler like "Oh" leaves the next word starting the sentence, keep that word as it was spoken (do not re-capitalize or otherwise alter it beyond what deletion requires).
3. Some transcripts contain no disfluencies at all. In that case, output the text completely unchanged.

WORKED EXAMPLES
- Input: "Oh yes. But, uh, we wouldn't ha-, we wouldn't have them, I mean, I don't see us without pets, without cats."
  Output: "yes. But, we wouldn't have them, I don't see us without pets, without cats."

OUTPUT
Return only the cleaned transcript text."""

CANDIDATES["prior-winner"] = PRIOR_WINNER

#: What a run must beat to be worth shipping: the best instruction we already have.
#: Was `guessed-default` — a guess at the service's own wording — back when nothing
#: measured was available to compare against. That candidate is still in the table as
#: a floor, but it is not the bar.
BASELINE = "prior-winner"
