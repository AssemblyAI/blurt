"""The cleanup instructions under test.

Each is a different hypothesis about what the dictation API's rewrite model needs
to be told, and each is a complete, shippable value for `config.llm.instruction`.
They vary one thing at a time: how the task is framed, how explicitly the
disfluency types are named, how hard the do-not-rewrite constraint is pushed, and
whether formatting is called out.

`default-proxy` stands in for the service's own default instruction — the empty
`llm` block Blurt sends today — so every run answers "did we beat what we already
ship", not just "which of these is best".

Kept in its own module so a results notebook or a re-scoring script can import the
instructions without pulling in argparse and DSPy.
"""

from __future__ import annotations

CANDIDATES: dict[str, str] = {
    "default-proxy": "Remove disfluencies and fix punctuation.",
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

# The instruction every run measures against, and the one Blurt effectively sends
# today by omitting `llm.instruction` entirely.
BASELINE = "default-proxy"
