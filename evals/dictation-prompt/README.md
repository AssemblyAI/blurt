# Dictation cleanup-prompt eval

A DSPy eval that searches for the best **cleanup instruction** for the dictation API's
LLM rewrite — the `config.llm` block Blurt sends on every `/transcribe` request.

Blurt sends `llm` as an empty object today, which selects the service's own default cleanup
instruction. This harness answers the question that comes next: is there an explicit
instruction that beats that default, and by how much? It scores candidate instructions on
how well they turn disfluent speech back into the text the speaker meant to write.

Nothing here ships in the app or runs in CI. It is offline tooling for deciding what string
(if any) should go into `config.llm.instruction`.

## How it works

1. **References** — reference transcripts are pulled from a Hugging Face **speech** dataset
   (default `google/fleurs`, `en_us`, `test`). These are hand-written transcriptions of
   sentences people actually spoke into a microphone, with real capitalization and
   punctuation, which makes them a fair target for "what did the user want on screen".
2. **Disfluency injection** — each reference is rendered as spontaneous speech: filler words,
   repeated words, cut-off stutters, false starts with a correction, clause restarts, and
   opening hedges. That is the messy verbatim text a speech-to-text model returns for
   off-the-cuff dictation. Injection is seeded, so a run is reproducible.
3. **Cleanup** — each candidate instruction runs as a single-step DSPy program over the
   disfluent text.
4. **Scoring** — the output is compared against the original reference by word error rate.
   Injection only ever _adds_ tokens, so the reference is exactly recoverable and a perfect
   prompt would score 1.0.
5. **Search** — with `--optimizer`, DSPy evolves a new instruction from the best hand-written
   one instead of only ranking the fixed set.

## Running it

```bash
export ANTHROPIC_API_KEY=...

# Rank the built-in candidate instructions on 150 utterances.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --limit 150 --out results.json

# Evolve a new instruction with GEPA (reflective prompt evolution).
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --optimizer gepa --limit 200

# Make punctuation and capitalization part of the job, not a given.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --strip-formatting

# No network, no API key: verify the data and scoring pipeline end to end.
python3 evals/dictation-prompt/optimize_cleanup_prompt.py --source builtin --dry-run
```

`uv run` reads the PEP 723 header at the top of the script and installs DSPy into a throwaway
environment. With plain `pip`, `pip install "dspy>=3.0"` is the only requirement.

The dry-run path imports nothing outside the standard library, which is why it works on a bare
interpreter — DSPy is imported lazily, inside the functions that need a model.

## The knobs that matter

| Flag                 | Default                   | What it changes                                                                              |
| -------------------- | ------------------------- | -------------------------------------------------------------------------------------------- |
| `--model`            | `anthropic/claude-opus-5` | The LiteLLM model standing in for the service's rewrite model.                               |
| `--api-base`         | —                         | Point at an OpenAI-compatible gateway instead of the provider's default endpoint.            |
| `--severity`         | `0.35`                    | 0–1; how often a disfluency is injected. Higher makes the task harder and noisier.           |
| `--strip-formatting` | off                       | Also lowercase and unpunctuate, so restoring formatting is part of the task.                 |
| `--metric`           | `blend`                   | `content` (words only), `format` (case and punctuation too), or 0.7/0.3 of both.             |
| `--optimizer`        | `none`                    | `gepa` or `mipro` to evolve an instruction; both are configured to search instructions only. |
| `--source`           | `datasets-server`         | `datasets` uses the library (for gated sets); `builtin` uses the bundled sample.             |
| `--seed`             | `7`                       | Seeds injection and the train/dev/test split.                                                |

Both optimizers run with few-shot demos disabled. `config.llm.instruction` is a single string
the service applies in one pass, so an optimized program that depended on bundled examples
would score well here and be unshippable.

## Reading the results

Every run prints an **echo floor**: the score of pasting the verbatim transcript with no
cleanup at all. That is the bar an instruction has to clear to be worth sending. It prints
`content` and `format` next to the selected metric, so you can see whether a winner gained on
wording or only on punctuation.

The winner is chosen on a dev split and then re-scored on a held-out test split, alongside
`default-proxy` — a stand-in for the service's default instruction — so the reported
improvement is measured on data no selection decision touched.

Because the disfluencies are synthetic, the **ranking** travels further than the absolute
numbers do. Read a result as "this instruction beats that one on this disfluency
distribution", not as a prediction of production quality. Re-run at a couple of `--severity`
values before trusting an ordering.

## Applying a winner

The winning string goes into the request's `config.llm.instruction`, next to the `prompt`
field that steers transcription. The Swift side is
`Sources/BlurtEngine/STT/AssemblyAITranscriber.swift`, where `LLMRewrite` is an empty
`Encodable` struct — encoding an empty `llm` object is what selects the service default today.

Two things to keep straight, both settled decisions in
[`AGENTS.md`](../../AGENTS.md#settled-decisions--dont-reintroduce-these):

- This is the **server-side** rewrite instruction. It is not a client-side cleanup pass, and
  the winning string is not a `TranscriptionPrompt` change — that prompt steers transcription
  and deliberately carries no filler-word clause, because disfluency removal is this rewrite's
  job.
- The positive-phrasing guidance in `TranscriptionPrompt` comes from AssemblyAI's Universal-3
  prompting reference and applies to the STT model. The cleanup instruction is read by an
  ordinary LLM, so the candidates here are phrased as plain instructions.

## Files

| File                         | What it holds                                                           |
| ---------------------------- | ----------------------------------------------------------------------- |
| `optimize_cleanup_prompt.py` | CLI, candidate instructions, DSPy program, optimizer wiring, reporting. |
| `disfluency.py`              | The seeded, additive disfluency injector.                               |
| `corpus.py`                  | Reference loading — HF rows API, `datasets`, JSONL, or bundled sample.  |
| `metrics.py`                 | Token alignment, the two word-error-rate axes, and GEPA feedback text.  |
| `test_eval.py`               | Offline tests for injection, scoring, loading, and splitting.           |

```bash
python3 -m pytest evals/dictation-prompt/test_eval.py
```

The tests need only `pytest` — they cover everything except the model calls, so they stay
green without a key.
