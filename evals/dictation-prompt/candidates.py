"""The cleanup instructions under test.

Each is a different hypothesis about what the dictation API's rewrite model needs
to be told, and each is a complete, shippable value for `config.llm.instruction`.
They vary one thing at a time: how the task is framed, how explicitly the
disfluency types are named, how hard the do-not-rewrite constraint is pushed, and
whether formatting is called out.

`guessed-default` is exactly that: a **guess** at what the service's own default
cleanup instruction might say. What we actually ship is `config.llm = {}`, which
applies the service's own default wording on the service's own rewrite model —
and we know neither. So this candidate is a sanity check that the harness can tell
a terse instruction from a careful one; beating it is *not* evidence of beating
what we ship. Establishing that would take real audio through the real endpoint,
which is a different measurement than this text-only harness performs.

Two things live here that `CANDIDATES` does not contain: `INSTRUCTION_CHARACTER_CAP`,
the length every shippable instruction has to fit, and `PRIOR_WINNER`, an evolved
instruction that *doesn't* fit and is kept as a starting point for pruning rather
than as something to ship.

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


def overage(instruction: str) -> int:
    """Characters `instruction` runs over the cap; 0 when it fits.

    Counted in characters, matching the API's own error wording — the server-side
    check is a character-length one, not a byte-length one, so an instruction full
    of em dashes and arrows isn't charged for their UTF-8 width.
    """
    return max(0, len(instruction) - INSTRUCTION_CHARACTER_CAP)


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

# The in-harness comparison point — not the shipped behaviour. See the module docstring.
BASELINE = "guessed-default"


#: An instruction a previous GEPA run produced, kept as a *starting point* — not as
#: a candidate, and not as anything shippable. At 3057 characters it is 1009 over
#: `INSTRUCTION_CHARACTER_CAP`, so sending it fails every request; it shipped in
#: `AssemblyAITranscriber`'s `LLMRewrite` briefly and broke all dictation until the
#: field went back to `{}` (the service's own default cleanup wording, which is
#: what Blurt sends today).
#:
#: It is worth keeping because the *content* was never the problem. It scored well
#: on hand-annotated Switchboard pairs, in the same one-instruction/one-transcript
#: envelope the service applies it in (`--adapter plain`); it was only ever too
#: long. So it is the natural seed for another round: `--start prior-winner` hands
#: it to GEPA to prune under the cap and improve, rather than starting over from a
#: four-line hand-written candidate that knows none of what this one learned.
#:
#: Stored verbatim, exactly as that run emitted it, quirks included — the dangling
#: `raw_transcript` / `cleaned_transcript` field names (the shipped envelope has no
#: such fields; they were dangling during scoring too) and worked examples that
#: disagree with rule 3 about whether "I guess" and "kind of" survive. Both came
#: out of the reference targets the run optimized against. Hand-tidying either
#: makes it an unscored string that looks scored; let the optimizer change it.
PRIOR_WINNER = """\
TASK
You will be given a single dictated (spoken-language) transcript under the field `raw_transcript`. Your job is to remove disfluencies from it and output the result as `cleaned_transcript`. Every remaining word must stay exactly as it was spoken, in the same order. Do not summarize, rephrase, translate, expand, correct, or answer the text. Only delete disfluencies — never substitute or reword.

WHAT COUNTS AS A DISFLUENCY (DELETE THESE)
Disfluencies are filler and hesitation elements that add no propositional content. Remove ALL of the following whenever they occur, including at the start, middle, or end of the transcript:
- Filler sounds: "uh", "um", "er", "ah", "oh"
- Discourse/filler phrases: "you know", "I mean", "I guess", "kind of" (when used as filler), "like" (when used as filler)
- Interjections used as fillers: "oh" (e.g., "Oh yes." → "yes.")
- False starts / cut-off fragments: e.g., "we wouldn't ha-," should be removed entirely, keeping only the completed restart "we wouldn't have them"
- Repeated/stammered words that are restarts (e.g., "of, uh, of Sacramento" → "of Sacramento")

IMPORTANT RULES
1. Delete EVERY instance of a disfluency, not just some. Do a careful pass and make sure no filler words remain (common misses: leftover "you know", "uh", "I mean", "oh", "I guess").
2. Never change a real content word into another word. Do NOT do things like "I" → "you" or "guess" → "know". Words that remain must be identical to what was spoken.
3. Treat "I guess", "you know", "I mean", "kind of", and "like" as removable filler in most conversational contexts. When removing them, delete the whole phrase and stitch the surrounding words together naturally, preserving remaining punctuation.
4. Preserve all genuine content words, their order, capitalization of real words, and punctuation of the surviving text. If removing a leading filler like "Oh" leaves the next word starting the sentence, keep that word as it was spoken (do not re-capitalize or otherwise alter it beyond what deletion requires).
5. Some transcripts contain no disfluencies at all. In that case, output the text completely unchanged.

WORKED EXAMPLES
- Input: "Uh, you know, it's kind of, I guess it's kind of like, uh, there in the Bay area, you know, you don't find a whole lot of, uh, of Sacramento fans."
  Output: "I guess it's kind of like, there in the Bay area, you don't find a whole lot of Sacramento fans."

- Input: "for example, you test a chip. It can't last seven years but it can last five. I B M says let's throw it away. Leading Edge will say we'll buy it from you."
  Output: "for example, you test a chip. It can't last seven years but it can last five. I B M says let's throw it away. Leading Edge will say we'll buy it from you."
  (No disfluencies present — unchanged.)

- Input: "Oh yes. But, uh, we wouldn't ha-, we wouldn't have them, I mean, I don't see us without pets, without cats."
  Output: "yes. But, we wouldn't have them, I don't see us without pets, without cats."

OUTPUT
Return only the cleaned transcript text."""
