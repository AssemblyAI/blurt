# Frozen eval datasets

## `spoken-punctuation.jsonl`

80 dictated utterances that speak their own punctuation — `period`, `comma`,
`question mark`, `all caps` — and **nothing else**. The input differs from the target by
the commands alone: no disfluencies are injected, so no score here can be moved by
anything but the punctuation task.

```json
{
  "reference": "Can you send me the LATEST NUMBERS before the review meeting tomorrow morning?",
  "disfluent": "well can you sort of send me the caps on latest numbers caps off before the review um meeting tomorrow morning question mark",
  "operations": [
    "opener",
    "filler",
    "filler",
    "spoken:caps-on",
    "spoken:question-mark"
  ],
  "commands": [
    {
      "spoken": "caps on",
      "mark": "",
      "kind": "caps",
      "anchor": "",
      "words": ["latest", "numbers"]
    },
    {
      "spoken": "question mark",
      "mark": "?",
      "kind": "mark",
      "anchor": "morning",
      "words": []
    }
  ]
}
```

Every command is guaranteed to change something: a mid-utterance terminal mark forces the
mark _and_ the capital behind it, an internal comma forces a placement, and ALL CAPS forces
uppercase. A mark on the final word is never spoken, because that is the one an instruction
would produce unprompted.

`commands` records what was planted, which is the only reason the run can report how many
commands were **obeyed** rather than just how close the text came. `--jsonl` reads it back
exactly — see `corpus._utterances_from_jsonl` — so scoring this file is scoring the corpus
it was generated from, not an approximation of it.

### Regenerating it

```bash
python3 evals/dictation-prompt/optimize_cleanup_prompt.py \
  --source punctuation --punctuation-only --limit 200 --spoken-caps-rate 0.35 --seed 7 \
  --dump-corpus evals/dictation-prompt/data/spoken-punctuation.jsonl \
  --dry-run --show-samples 0
```

No network and no API key: `builtin` is bundled and both injectors are seeded.
`test_eval.py` runs exactly this and asserts the result is byte-identical to the committed
file, so a change to either injector fails the suite instead of silently invalidating a
dataset that is still in the tree.

### Why this corpus and not the real one

The measurement corpus is `nyra` — ~5k Switchboard utterances whose disfluencies trained
annotators marked by hand — and it is **not** committed here. It derives from
LDC-licensed transcripts, and `corpus.BUILTIN_SAMPLE` exists precisely so the offline path
carries no third-party licensing. Dump it locally if you want it frozen:

```bash
python3 evals/dictation-prompt/optimize_cleanup_prompt.py --punctuation-only \
  --limit 4000 --dump-corpus /tmp/nyra-punctuation.jsonl --dry-run --show-samples 0
```

So read this file as a **fixture**, not a benchmark. 80 rows split into 53 dev / 26 test is
far below the resolution the parent README argues for — differences between good
instructions on this task are a few hundredths, and 26 test rows cannot see them. What it
is good for: reading the examples, reviewing a diff when an injector changes, and the one
thing `nyra` genuinely cannot do — **literal-use traps**. 14% of these references use a
command word as ordinary content ("one grace period, so plan accordingly", "add a comma
after the second clause"), against ~0–1% of `nyra`'s, so this is the only corpus here that
can charge an instruction for converting a word the speaker meant literally.
