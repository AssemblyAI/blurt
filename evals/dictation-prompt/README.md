# Dictation cleanup-prompt eval

A DSPy eval that searches for the best **cleanup instruction** for the dictation API's
LLM rewrite — the `config.llm` block Blurt sends on every `/transcribe` request.

Blurt sends `llm` as an empty object today, which selects the service's own default cleanup
instruction. This harness answers the question that comes next: is there an explicit
instruction that beats that default, and by how much? It scores candidate instructions on
how well they turn a disfluent transcript back into the text the speaker meant to write.

The Python here is offline decision support — it is not shipped, not built, and not run by
`scripts/check.sh`. (Its Markdown _is_ linted, like every other `.md` in the repo.)

## The corpora

Each source supplies `(disfluent input, clean target)` pairs. The first two are **real**:
the disfluencies are the ones actual speakers produced and human annotators labelled, not
ones we thought to write down.

| `--source`                    | What it is                                                                                                                                                                                                                                  | Measures         |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| `disfluency-speech` (default) | [`amaai-lab/DisfluencySpeech`][ds] — ~5k Switchboard utterances whose disfluencies trained annotators marked **by hand** under the LDC stylebook. Scores `transcript_a` (as spoken) against `transcript_c` (false starts and fillers gone). | content only     |
| `nyra`                        | [`nyralabs/disfluency_speech_english`][nyra] — the same corpus repackaged with casing repaired, at some cost in fidelity.                                                                                                                   | content + format |
| `disfl-qa`                    | [`google-research-datasets/disfl_qa`][dq] — ~12k SQuAD questions with a human-written disfluent variant.                                                                                                                                    | content + format |
| `fleurs`                      | [`google/fleurs`][fl] read speech, made disfluent by the injector in `disfluency.py`.                                                                                                                                                       | content + format |
| `builtin`                     | A dozen bundled sentences plus injection. No network, no key — for smoke-testing.                                                                                                                                                           | content + format |

`--jsonl` reads a local file instead: objects with both `disfluent` and `reference` are used
as-is; anything with only a reference goes through the injector.

**Why keep synthetic injection at all**, now that real pairs exist? Three things it does that
a fixed corpus can't: a **severity dial** (`--severity`) for checking whether a ranking
survives more or less disfluent input; a **punctuation-restoration** task via
`--strip-formatting`, which no real corpus here poses (their inputs and targets are
punctuated alike); and an **offline path**.

**Why `disfl-qa` alongside `nyra`**: over 90% of its disfluencies are corrections and
restarts — deliberately the hard cases. Switchboard is over half simple repetitions, and the
injector is weighted the same way, so `disfl-qa` covers the tail the other two under-sample.

### How the hand annotation reaches the eval

`DisfluencySpeech`'s `transcript_annotated` column carries Switchboard's own markup —
`{D}` discourse marker, `{F}` filled pause, `{E}` editing term, `[ reparandum + repair ]`,
`<laughter>` — produced by trained annotators. Its `transcript_a`/`_b`/`_c` columns are that
markup mechanically stripped at three levels, so **the judgment is human and the derivation is
a rule**. We take `a` → `c`: every word as spoken (`bam-` cut-offs and all, exactly what a
transcriber emits) against the fully cleaned version.

### What each corpus cannot tell you

Mechanical stripping is why `disfluency-speech` cannot score formatting: removing a
sentence-initial `{D Well, }` leaves the next word lowercase (`Yeah. rabbits are darling`), so
a cleanup that correctly writes `Rabbits` would be marked wrong. The harness refuses to let
that pass silently — `--metric blend` degrades to `content` with a note, and an explicit
`--metric format` is an error pointing at the alternatives.

`nyra` is the same corpus with that casing repaired, which is what makes its formatting axis
usable. It pays for it in fidelity: it retains repetitions the hand annotation marked as
reparanda, and rewrites the verbatim side into its own conventions (`[UH]`, `[laughter]`,
`th*`) that the loader has to undo. Prefer it when formatting matters more than exact recall.

Neither poses punctuation _restoration_, since both sides are already punctuated. Only
`--source fleurs --strip-formatting` does.

[nyra]: https://huggingface.co/datasets/nyralabs/disfluency_speech_english
[ds]: https://huggingface.co/datasets/amaai-lab/DisfluencySpeech
[dq]: https://huggingface.co/datasets/google-research-datasets/disfl_qa
[fl]: https://huggingface.co/datasets/google/fleurs

## Running it

```bash
export ANTHROPIC_API_KEY=...

# Rank the built-in candidate instructions on hand-annotated Switchboard pairs.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --limit 150 --out results.json

# The hard disfluency types — corrections and restarts.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --source disfl-qa --limit 200

# Does it restore punctuation and capitalization? Only this combination asks.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --source fleurs --strip-formatting

# A larger run: the held-out splits are only ~250 rows, so reach into train.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py \
  --split train --limit 600 --dev-fraction 0.5 --test-fraction 0.5 --out results.json

# Evolve a new instruction with GEPA (reflective prompt evolution).
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --optimizer gepa --split train --limit 400

# No network, no API key: verify the corpus and scoring pipeline end to end.
python3 evals/dictation-prompt/optimize_cleanup_prompt.py --source builtin --dry-run
```

`uv run` reads the PEP 723 header at the top of the script and installs DSPy into a throwaway
environment. With plain `pip`, `pip install "dspy>=3.0"` is the only requirement.

The dry-run and the tests import nothing outside the standard library. That is structural, not
a convention: everything touching DSPy lives in `program.py`, which the CLI imports only after
the dry-run returns. Two tests hold the line — one that the dry-run never reaches `program`,
one that no other module imports `dspy` at all.

A sweep is hundreds of paid calls, so it shows a progress meter across the whole run rather
than going quiet between candidates. On a terminal it rewrites one line in place; piped to a
log it prints a line per decile, since carriage returns in a file make one unreadable line.

## The knobs that matter

| Flag                 | Default                   | What it changes                                                                              |
| -------------------- | ------------------------- | -------------------------------------------------------------------------------------------- |
| `--source`           | `disfluency-speech`       | Which corpus to score against — see the table above.                                         |
| `--model`            | `anthropic/claude-opus-5` | The LiteLLM model standing in for the service's rewrite model.                               |
| `--api-base`         | —                         | Point at an OpenAI-compatible gateway instead of the provider's default endpoint.            |
| `--metric`           | `blend`                   | `content` (words only), `format` (case and punctuation too), or 0.7/0.3 of both.             |
| `--severity`         | `0.35`                    | 0–1; how often a disfluency is injected. Reference-only sources only.                        |
| `--strip-formatting` | off                       | Also lowercase and unpunctuate, so restoring formatting is part of the task.                 |
| `--optimizer`        | `none`                    | `gepa` or `mipro` to evolve an instruction; both are configured to search instructions only. |
| `--loader`           | `datasets-server`         | `datasets` uses the library instead of the HTTP rows API, for gated sets.                    |
| `--split`            | per source                | Each source defaults to its held-out split, which is small — `--split train` for large runs. |
| `--seed`             | `7`                       | Seeds injection and the train/dev/test split.                                                |

Both optimizers run with few-shot demos disabled. `config.llm.instruction` is a single string
the service applies in one pass, so an optimized program that depended on bundled examples
would score well here and be unshippable.

## What this can and cannot establish

The harness is deliberately text-only: a transcript goes in, an instruction transforms it, the
output is scored against the target. That keeps it cheap, fast, and reproducible, and it is the
right shape for ranking instructions against each other.

It does not measure the thing we ship. Blurt sends `config.llm = {}`, which applies **the
service's own default cleanup instruction, on the service's own rewrite model** — neither of
which we know. The `guessed-default` candidate is a guess at the first and ignores the second,
and is named that way on purpose. Treat a win over it as "this instruction is better than a
terse one on our stand-in model", not as "this beats what we ship".

Two consequences worth holding onto when reading a result:

- A winner is only as transferable as `--model` is representative of the service's rewrite
  model, which runs under a ~5s budget and is probably much smaller.
- Confirming a win against the live default would mean sending real audio to
  `dictation.assemblyai.com/transcribe` with an empty `llm` block and comparing. That is a
  separate exercise, not this one.

## Reading the results

Every run prints a **no-cleanup floor**: the corpus's disfluent side scored against its own
target, with no request made and no model involved. It is the floor of the _metric_, not of
the product — with enhanced transcripts on, the service always cleans something, so "paste the
raw transcript" isn't a state Blurt can be in. Read it as how much work the corpus contains.
It also prints what
fraction of pairs actually differ from their target — the rest are clean utterances, which
test the opposite failure (over-editing text that needed nothing).

All three axes are printed for every candidate, with the selecting one starred, so you can
see whether a winner gained on wording or only on punctuation. The winner is chosen on a dev
split and re-scored on a held-out test split alongside `guessed-default` — a guess at the
service's default instruction, not the thing itself; see above — so the reported improvement is
measured on data no selection decision touched.

On a real corpus the numbers mean what they say. On `fleurs` and `builtin` the disfluencies
are synthetic, so the **ranking** travels further than the absolute scores do: read those as
"this instruction beats that one on this disfluency distribution", and re-run at a couple of
`--severity` values before trusting an ordering.

## Applying a winner

The winning string goes into the request's `config.llm.instruction`, next to the `prompt`
field that steers transcription. The Swift side is
`Sources/BlurtEngine/STT/AssemblyAITranscriber.swift`, where `LLMRewrite` is an empty
`Encodable` struct — encoding an empty `llm` object is what selects the service default today.

Three things to keep straight, all settled decisions in
[`AGENTS.md`](../../AGENTS.md#settled-decisions--dont-reintroduce-these):

- This is the **server-side** rewrite instruction. It is not a client-side cleanup pass, and
  the winning string is not a `TranscriptionPrompt` change — that prompt steers transcription
  and deliberately carries no filler-word clause, because disfluency removal is this rewrite's
  job.
- The positive-phrasing guidance in `TranscriptionPrompt` comes from AssemblyAI's Universal-3
  prompting reference and applies to the STT model. The cleanup instruction is read by an
  ordinary LLM, so the candidates here are phrased as plain instructions.
- **Every corpus here is English, and the prompt is not.** `config.llm.instruction` ships to
  every user in every language, and pinning the transcription prompt to English was reverted
  once already for hurting non-English transcription. A winner selected on this harness has
  only been shown to work in English; weigh that before shipping a long, English-shaped
  instruction.

## Files

| File                         | What it holds                                                             |
| ---------------------------- | ------------------------------------------------------------------------- |
| `optimize_cleanup_prompt.py` | CLI, axis resolution, reporting.                                          |
| `candidates.py`              | The cleanup instructions under test.                                      |
| `corpus.py`                  | Sources, loading, de-tagging, splitting, the echo floor.                  |
| `disfluency.py`              | The seeded, additive disfluency injector.                                 |
| `metrics.py`                 | Token alignment, the two word-error-rate axes, GEPA feedback text.        |
| `program.py`                 | Everything that imports DSPy — the program, metrics adapters, optimizers. |
| `test_eval.py`               | Offline tests for injection, scoring, de-tagging, loading, and splitting. |

```bash
python3 -m pytest evals/dictation-prompt/test_eval.py
```

The tests need only `pytest` — they cover everything except the model calls, so they stay
green without a key.
