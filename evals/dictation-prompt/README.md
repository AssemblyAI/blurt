# Dictation cleanup-prompt eval

A DSPy eval that searches for the best **cleanup instruction** for the dictation API's
LLM rewrite — the `config.llm` block Blurt sends on every `/transcribe` request.

Blurt sends `llm` as an empty object today, which selects the service's own default cleanup
instruction. This harness answers the question that comes next: is there an explicit
instruction that beats that default, and by how much? It scores candidate instructions on
how well they turn a disfluent transcript back into the text the speaker meant to write.

The Python here is offline decision support — nothing in it ships inside the app. It is still
gated by `scripts/check.sh`, which runs `ruff format --check` and `ruff check` over `evals/`
(config in [`../ruff.toml`](../ruff.toml)) and `pytest` over `test_eval.py`. All three are
platform-independent, so they run in the `--portable` subset too — an eval change can be
verified off-Mac. A harness whose own correctness is unchecked is a bad instrument.

## The corpora

Each source supplies `(disfluent input, clean target)` pairs. The first two are **real**:
the disfluencies are the ones actual speakers produced and human annotators labelled, not
ones we thought to write down.

| `--source`                    | What it is                                                                                                                                                                                                                                  | Measures         |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| `disfluency-speech` (default) | [`amaai-lab/DisfluencySpeech`][ds] — ~5k Switchboard utterances whose disfluencies trained annotators marked **by hand** under the LDC stylebook. Scores `transcript_a` (as spoken) against `transcript_c` (false starts and fillers gone). | content only     |
| `nyra`                        | [`nyralabs/disfluency_speech_english`][nyra] — the same corpus repackaged with casing repaired, at some cost in fidelity.                                                                                                                   | content + format |
| `disfl-qa`                    | [`google-research-datasets/disfl_qa`][dq] — ~12k SQuAD-v2 questions with a human-inserted self-correction. A QA **robustness** benchmark, not a cleanup corpus — see the warning below before tuning on it.                                 | content + format |
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
# The gateway is OpenAI-compatible, so the SDK reads OPENAI_API_KEY.
export OPENAI_API_KEY=$ASSEMBLYAI_API_KEY

# The whole recommended run, with nothing to pass. See "What the defaults do" below.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --out results.json

# Cheap first: rank the hand-written candidates, no search. Do this when changing
# corpus or model, so a bad setup shows up before a paid search runs on top of it.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --optimizer none --limit 100

# Evolve from the best hand-written candidate instead of the prior winner.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --start best-candidate

# The hard disfluency types — corrections and restarts.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --source disfl-qa

# Does it restore punctuation and capitalization? Only this combination asks.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --source fleurs --strip-formatting

# A frontier model on its own endpoint rather than the gateway. `--api-base ""` clears
# the gateway; without it the anthropic/ id would be sent to the wrong host.
ANTHROPIC_API_KEY=... uv run evals/dictation-prompt/optimize_cleanup_prompt.py \
  --model anthropic/claude-opus-5 --api-base "" --reflection-model anthropic/claude-opus-5

# Less search, for a cheaper look: --auto is the only knob that changes trial count.
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --auto light

# No network, no API key: verify the corpus and scoring pipeline end to end.
python3 evals/dictation-prompt/optimize_cleanup_prompt.py --source builtin --dry-run
```

### Where the headroom is, and where it is a mirage

The default corpus is chosen for **room to improve on the task the product actually does**.
Those are two conditions, and the second one matters more. Measured with no model involved —
the corpus's disfluent side against its own target, plus the median share of input words each
corpus asks to be deleted and how much of that is filler:

| `--source`          | no-cleanup floor | words deleted | of those, fillers | task           |
| ------------------- | ---------------- | ------------- | ----------------- | -------------- |
| `disfluency-speech` | 0.834            | 11%           | 75%               | remove fillers |
| **`nyra`**          | **0.789**        | 13%           | 67%               | remove fillers |
| `disfl-qa`          | 0.435            | 31%           | **0%**            | something else |

Switchboard is close to saturated. The shipped instruction scores 0.910 against its 0.834
floor, so it is worth +0.077 and already holds about half of everything available — which is
why two searches in a row could not beat it. The remaining gap between a good instruction and
a great one is a few thousandths, under the run-to-run noise. That is a property of the
corpus, not a failure of the optimizer.

`disfl-qa`'s floor of 0.435 looks like the answer and is not. It deletes 31% of the input and
**none of it is filler**: the task is to spot a self-correction and discard the abandoned first
attempt, real content words and all — sometimes rewording what survives, since 11% of its
targets contain words absent from the input and so cannot be reached by deletion at all.

Its construction says why. Disfl-QA exists to "serve as a benchmark dataset for testing
robustness of models against disfluent inputs": annotators took SQuAD-v2 questions and inserted
a contextual disfluency "using the paragraph as a source of distractors", which is how you get
_"the second level of territorial division in **Poland** no make that the basic unit of
territorial division in **Warsaw**"_. "Poland" is not a speaker's slip — it is a semantic decoy
harvested from the passage, planted to see whether a QA model is fooled. Over 90% of the
disfluencies are corrections or restarts by design, because the point was a hard test set.

None of that resembles someone dictating. An instruction tuned there learns to discard content
words, which is precisely what `CleanupInstruction` forbids, and headroom from measuring a
different task is worth nothing. It stays useful for the thing it was built for: a stress test
of whether an instruction over-deletes when a restart appears.

`nyra` is the same hand-annotated Switchboard data with casing repaired. It buys about 27% more
room (floor 0.789 against 0.834) on the same task, and — the larger gain — its formatting is
measurable, so `--metric blend` scores two axes instead of degrading to `content` as it must on
`disfluency-speech`. It pays for that in fidelity: it keeps repetitions the hand annotation
marked as reparanda and rewrites the verbatim side into its own conventions, so a run on it
closes by printing the command to re-check the winner against the unmodified pairs.

### What the defaults do

A bare invocation is a full paid GEPA run, so it is worth knowing what it commits to.

| Default                                     | Why                                                                                                                                                                                                                                                               |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--model openai/qwen3.5-4b-32k-fast`        | The service's own rewrite runs under a ~5 s budget and is probably small, so a small stand-in is the faithful one. An instruction tuned against a frontier model can lean on comprehension the real one lacks. `openai/` is the wire protocol, not the vendor.    |
| `--api-base …llm-gateway.assemblyai.com/v1` | Where that model lives. Applies to the reflection model too. Pass `""` to use a provider's own endpoint.                                                                                                                                                          |
| `--reflection-model openai/claude-opus-4-8` | Deliberately not `--model`: a 4B model writing its own instructions is the weakest link in the loop.                                                                                                                                                              |
| `--adapter plain`                           | Sends the instruction as the system turn and the transcript as the user turn — the envelope the service applies `llm.instruction` in. Small models can't follow DSPy's marker protocol at all.                                                                    |
| `--optimizer gepa` · `--start prior-winner` | Evolve from `candidates.PRIOR_WINNER` — the strongest instruction we have, and `BASELINE` — rather than restarting from a four-line candidate that knows none of what it learned. It fits the cap, so the search starts inside the feasible region.               |
| `--auto heavy`                              | 27 reflection trials (light is 10, medium 18). This is the **only** knob that changes how many ideas get tried — corpus size does not. Merge is off: crossover needs more than one predictor, so it would only re-evaluate duplicates.                            |
| `--split train --limit 2000`                | The sources' own held-out splits are only ~250 rows. Everything past dev and test becomes train, and train rows are free — see below.                                                                                                                             |
| `--dev-fraction 150` (rows, not a fraction) | Dev decides which instruction ships — `BASELINE` versus the optimizer's result — and the optimizer never sees it. Sized for a decision you can trust rather than for the search.                                                                                  |
| `--gepa-valset 50` (rows)                   | The optimizer's own valset, carved off train. Every surviving candidate is scored against all of it, so its size multiplies search cost while buying no exploration — that is `--auto` alone.                                                                     |
| `--reflection-minibatch-size 8`             | Scored examples the reflector sees before rewriting. GEPA's default is 3, which on a task this well-solved is often three near-perfect examples and almost no failure to generalise from.                                                                         |
| `--test-fraction 150` (rows)                | The honest number, from data no selection step saw. Scored twice at the end.                                                                                                                                                                                      |
| `--candidates baseline`                     | A search run scores only `BASELINE` on dev — it is the bar, the fallback and the seed at once, so the other six cost a dev sweep each to re-rank instructions the search never uses. `--optimizer none` scores all of them, since there the ranking is the point. |
| `--num-threads 1`                           | The gateway rate-limits; a 429 storm mid-run costs more wall-clock than the concurrency saves. Raise it for a provider that tolerates it.                                                                                                                         |
| `--max-tokens 8192`                         | Headroom for reasoning tokens, not for the answer. Truncation here is silently corrupting — see below.                                                                                                                                                            |

That leaves **train 1650 / optimizer valset 50 / dev 150 / test 150**, for roughly 2,000 model
calls: 150 to score `BASELINE`, ~1,385 for the search, 150 to re-score its result, and 300 for
the two held-out scorings at the end.

**Three sets, three jobs, and no overlap.** The optimizer tracks candidates against its own
valset (carved off train), dev decides which instruction ships, and test is the number
reported. Until these were separated the optimizer's valset _was_ dev — so the rows that
steered the search also judged its result, and a search that overfit 50 rows would report the
overfitting as a win. Test still exists on top of that, because dev now makes a selection and a
set that makes a selection cannot also be the honest number.

Three of these are worth understanding rather than just accepting:

**Train rows are free; dev and test are not.** This is why `--dev-fraction` and
`--test-fraction` default to absolute row counts (they read as fractions below 1, as counts at
1 or above — the `train_test_split` convention). The three slices have very different costs:

| Consumer                                     | Slice | Cost                                               |
| -------------------------------------------- | ----- | -------------------------------------------------- |
| GEPA reflection minibatches                  | train | 18 × 35 = 630 calls — **fixed, whatever train is** |
| GEPA valset full evals                       | dev   | scales with dev                                    |
| Ranking the candidates, the seed, re-scoring | dev   | **8 × dev**                                        |
| Final held-out scoring                       | test  | 2 × test                                           |

So raising `--limit` grows only the free slice and buys more varied reflection material at no
extra model cost. Tying dev and test to `--limit` by fraction would have scaled the two
expensive slices along with it for nothing. The real ceilings on `--limit` are the corpus
(`disfluency-speech` is ~5k utterances) and the datasets-server rate limit — set `HF_TOKEN`
before a large load.

**Truncation poisons a run rather than failing it.** `--adapter plain` means the whole
completion _is_ the answer — there are no field markers to parse. So a completion cut off at
`--max-tokens` becomes a truncated "cleaned transcript", scores badly against its reference,
and teaches GEPA that a perfectly good instruction produces bad cleanups. The symptom is a
`WARNING dspy.clients.lm: LM response was truncated` line and a disappointing score, not an
error. Reasoning tokens count against the same budget, which is why the default is far above
what a one-sentence answer needs; unused headroom costs nothing.

**Dev does double duty, and 50 rows is small for the second job.** It is GEPA's valset _and_
the set that ranks the hand-written candidates, scores the seed, and decides whether the
evolved instruction beats them — the decision that picks what ships. At 50 rows that decision
is noticeably noisier. The held-out test scores are unaffected, so the risk is shipping a
slightly worse instruction, not misreporting one. Raise `--dev-fraction` to 0.15–0.2 if you
care more about a confident selection than about search cost.

`uv run` reads the PEP 723 header at the top of the script and installs DSPy into a throwaway
environment. With plain `pip`, `pip install "dspy>=3.0"` is the only requirement.

Anonymous reads of the Hugging Face datasets-server are rate limited, so a long run — or a few
short ones back to back — will start getting 429s. Authenticating lifts the limit: run
`hf auth login` with a read token from [huggingface.co/settings/tokens][tok], or set `HF_TOKEN`
in the environment. Either works; the loader resolves a token the same way `huggingface_hub`
does, so whichever one you reach for is the one it reads.

[tok]: https://huggingface.co/settings/tokens

The dry-run and the tests import nothing outside the standard library. That is structural, not
a convention: everything touching DSPy lives in `program.py`, which the CLI imports only after
the dry-run returns. Two tests hold the line — one that the dry-run never reaches `program`,
one that no other module imports `dspy` at all.

A sweep is hundreds of paid calls, so it shows a progress meter across the whole run rather
than going quiet between candidates. On a terminal it rewrites one line in place; piped to a
log it prints a line per decile, since carriage returns in a file make one unreadable line.

### What actually reaches the model

`--adapter plain`, the default, sends the candidate instruction as the system message and the
transcript as the user message, and takes the whole reply as the cleaned text. That is the
shape the service applies `config.llm.instruction` in: one instruction, one transcript, one
pass, no envelope.

DSPy's own `ChatAdapter` (`--adapter chat`) instead wraps both sides in `[[ ## field ## ]]`
markers and restates the instruction as "In adhering to this structure, your objective is: …",
so a score under it reflects the instruction _plus_ that scaffolding — and not even the
instruction as written. Small models can't follow the protocol at all: `qwen3.5-4b-32k-fast`
echoes the user message back verbatim, nothing parses, and DSPy's automatic retry in JSON mode
then sets `response_format`, which the LLM Gateway rejects with a 400 for models that don't
support it. Results recorded before `plain` became the default aren't comparable with results
after it.

### Which model does what

Three roles, worth keeping apart when reading a result:

| Role                                                | Set by                     | Notes                                                                                                        |
| --------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Applies the instruction to a transcript             | `--model`                  | The only one standing in for the service's rewrite model — the thing under test.                             |
| Scores the output                                   | nothing; no model involved | Deterministic word error rate against the reference. No LLM judge, so nothing can flatter a weak `--model`.  |
| Proposes new instructions, under `--optimizer gepa` | `--reflection-model`       | **Defaults to `--model`.** Leave it unset with a small `--model` and that model writes its own instructions. |

`--optimizer mipro` has no equivalent override: MIPROv2 proposes with `dspy.settings.lm`, which
is `--model`. Its proposal prompts are multi-field, so they keep DSPy's marker protocol and the
`response_format` retry behind it — which a small model on the gateway will reject. Prefer
`gepa` when `--model` is small.

## The knobs that matter

| Flag                 | Default                      | What it changes                                                                                        |
| -------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------ |
| `--source`           | `disfluency-speech`          | Which corpus to score against — see the table above.                                                   |
| `--model`            | `openai/qwen3.5-4b-32k-fast` | The LiteLLM model standing in for the service's rewrite model.                                         |
| `--reflection-model` | `openai/claude-opus-4-8`     | Writes the instructions during `--optimizer gepa`. Keep it stronger than `--model`.                    |
| `--api-base`         | the AssemblyAI gateway       | Endpoint for both models. `""` falls back to the provider's own.                                       |
| `--adapter`          | `plain`                      | `plain` sends instruction + transcript as one chat turn; `chat` uses DSPy's field markers.             |
| `--metric`           | `blend`                      | `content` (words only), `format` (case and punctuation too), or 0.7/0.3 of both.                       |
| `--severity`         | `0.35`                       | 0–1; how often a disfluency is injected. Reference-only sources only.                                  |
| `--strip-formatting` | off                          | Also lowercase and unpunctuate, so restoring formatting is part of the task.                           |
| `--optimizer`        | `gepa`                       | `none` only ranks the candidates; both optimizers search instructions only.                            |
| `--start`            | `prior-winner`               | Which instruction GEPA evolves from — the compressed prior winner, or the best hand-written candidate. |
| `--auto`             | `heavy`                      | Reflection trials: 10 / 18 / 27. The only knob that changes how many ideas get tried.                  |
| `--loader`           | `datasets-server`            | `datasets` uses the library instead of the HTTP rows API, for gated sets.                              |
| `--split`            | `train`                      | The sources' own held-out splits are only ~250 rows — too few for the default `--limit`.               |
| `--limit`            | `2000`                       | Rows loaded, then sliced 1800 train / 50 dev / 150 test. Train rows cost nothing.                      |
| `--dev-fraction`     | `150` (rows)                 | Fraction below 1, absolute count at 1 or above. Decides what ships; the search never sees it.          |
| `--gepa-valset`      | `50` (rows)                  | The optimizer's valset, taken off train. Multiplies search cost, adds no exploration.                  |
| `--test-fraction`    | `150` (rows)                 | Same convention. Scored twice, and by nothing that makes a selection.                                  |
| `--num-threads`      | `1`                          | Serial by default — the gateway rate-limits.                                                           |
| `--max-tokens`       | `8192`                       | Headroom for reasoning tokens. Too low silently corrupts a run rather than failing it.                 |
| `--seed`             | `7`                          | Seeds injection and the train/dev/test split.                                                          |

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

Each axis is `1 - WER`. That is 1.0 for an exact match and **exactly 0 for "as bad as saying
nothing"**, since an empty hypothesis deletes every reference word for a WER of 1. Below that
the score keeps going, decaying toward -1 rather than clipping: a degenerate output (a
repetition loop, a refusal) has to stay distinguishable from a merely bad one, or GEPA's
per-example Pareto front cannot prefer the near-miss. Nothing in the normal range is affected —
the piece above zero is plain `1 - WER`, so scores from before this change still compare.

All three axes are printed for every candidate, with the selecting one starred, so you can
see whether a winner gained on wording or only on punctuation. The winner is chosen on a dev
split and re-scored on a held-out test split alongside `BASELINE` — `prior-winner`, the best
instruction we already have — so the reported improvement is measured on data no selection
decision touched, against the thing a new instruction would actually replace.

On a real corpus the numbers mean what they say. On `fleurs` and `builtin` the disfluencies
are synthetic, so the **ranking** travels further than the absolute scores do: read those as
"this instruction beats that one on this disfluency distribution", and re-run at a couple of
`--severity` values before trusting an ordering.

## Applying a winner

The winning string goes into the request's `config.llm.instruction`, next to the `prompt`
field that steers transcription. The Swift side is
`Sources/BlurtEngine/STT/AssemblyAITranscriber.swift`, where `LLMRewrite` is an empty
`Encodable` struct — encoding an empty `llm` object is what selects the service default today.

Store it **verbatim**, exactly as the run emitted it. The harness scores instructions through
the same envelope the service applies them in (see `--adapter plain`), so the string
as-emitted is the string that was measured; a hand-tidied copy is an unscored string that
looks scored.

### The 2048-character cap

`config.llm.instruction` accepts at most **2048 characters**. Over that, the API rejects the
whole request — HTTP 400 `bad_request`, _"llm.instruction: String should have at most 2048
characters"_ — before it looks at the audio. There is no degraded mode: no transcript comes
back, so in the app every dictation fails with the overlay's "Try again".

Two things make this easy to get wrong, and it has gone wrong once already — a 3057-character
GEPA winner shipped and broke all dictation:

- **It is not the same cap as `config.prompt`'s**, which is 4096 (`TranscriptionPrompt.characterCap`
  on the Swift side). Borrowing the prompt's figure is what let the oversized instruction
  through: the test that should have caught it asserted 4096.
- **Neither limit is in the published API reference.** Both were measured against the live
  endpoint on 2026-08-11. Re-probe before trusting them indefinitely.

### The safeguards the corpus cannot defend

`PRIOR_WINNER` forbids answering the transcript and forbids translating it. Those clauses are
why dictating "what time is it?" pastes the question instead of an answer, and why non-English
speech survives as spoken. **Nothing in the scoring can see either property**: every corpus
here is conversational English between two humans, so an instruction that drops them scores
exactly the same — while freeing ~90 characters under a cap the reflector is explicitly told to
cut toward. Deleting them is what a well-behaved optimizer _should_ do given what it can see.

So they are gated rather than measured, by the same `objections` mechanism as the length cap:
the proposer rejects and re-asks, and selection refuses a winner without them. Matching is on
stems (`answer`, `translat`), so any phrasing passes — a false accept is far cheaper than a
false reject that burns retries on a good instruction.

"Do not rephrase" is deliberately **not** gated. Substituting a content word raises WER
directly, so the score already defends that one. The gate is only for what nothing else sees.

The harness enforces the cap in three places, none of which is sufficient alone:

| Where                                        | What it catches                                      | Strength                     |
| -------------------------------------------- | ---------------------------------------------------- | ---------------------------- |
| `check_candidate_lengths()`, before any call | A hand-written candidate in `candidates.py`          | Hard — exits before spending |
| GEPA feedback text (`--optimizer gepa`)      | Tells the reflector the ceiling as it rewrites       | Advisory — it can ignore it  |
| `CappedInstructionProposer` (GEPA only)      | An over-cap proposal, before GEPA ever scores it     | Hard — rejects and re-asks   |
| `CappedInstructionProposer` (GEPA only)      | A proposal naming a DSPy signature field             | Hard — rejects and re-asks   |
| Selection, after the run                     | An over-cap optimizer result, however well it scored | Hard — refuses to report it  |

The third row is the one that makes this a search constraint rather than a report. Length
cannot enter the objective: GEPA's metric is handed one scored example and never sees the
candidate instruction, and longer instructions tend to score better, so an unconstrained search
drifts over the cap and the run ends with nothing sendable. `CappedInstructionProposer` is
GEPA's documented `instruction_proposer` hook — it delegates to GEPA's own reflection prompt,
then rejects any proposal over the cap and re-asks against the rejected draft with the overage
spelled out (`candidates.shortening_directive`). After three tries it returns the instruction
**unchanged** rather than a truncation: cutting at 2048 characters lands mid-sentence, and a
mangled instruction that happens to score well is how bad prompts reach a build. The run
reports how many proposals it rejected, so a search that spent itself fighting the cap is
visible rather than inferred from a disappointing score.

**MIPROv2 gets none of this.** It searches on a bare scalar and exposes no proposal hook, so
`--optimizer mipro` is constrained only by the final refusal; the CLI says so when you run it.

### Why the proposer also rejects field names

The harness's DSPy signature is `raw_transcript -> cleaned_transcript`, and GEPA's reflective
dataset is **keyed by those field names** — so the reflection model sees them as labels and
writes instructions that refer to them ("output the result as `cleaned_transcript`").

Those fields exist in neither envelope. `PlainChatAdapter` sends the bare transcript as the
user turn and the instruction as the system message, with no field scaffolding; the service
does the same. So the instruction describes a message the model never receives — and worse, it
invites the model to emit the label literally, which Blurt would paste into the user's
document. The eval is structurally unable to catch that: under `--adapter plain` the whole
completion is the answer, so if the small stand-in doesn't take the bait where the service's
rewrite model does, the score looks fine.

The leak regenerates every run, which is why it is a gate rather than a one-time fix. Both
faults are reported in the same re-ask, so one revision round fixes everything rather than
surfacing the next fault a round later.

**Nothing is exempt, `prior-winner` included.** That candidate is the instruction from the
run that broke dictation, compressed under the cap — see below — so it passes the same
pre-flight check as everything else, and if a later edit pushes it back over, the run stops
before spending anything.

### `prior-winner`, and how it got under the cap

`candidates.PRIOR_WINNER` is the strongest instruction the harness has produced. The run that
emitted it wrote 3057 characters, 1009 over the cap, and it shipped in that state once. It was
compressed **by deletion only** — no wording was introduced, only removed — and the one edit
that isn't a deletion is closing the gap in the rule numbering. Six removals, each a
duplicate, a contradiction, or a reference to something that doesn't exist: a redundant
taxonomy bullet, two rules that restated bullets above them, a worked example whose output
contradicted one of those rules, the no-op example a surviving rule already states in a line,
the two clauses naming DSPy signature fields (see above), and the whole IMPORTANT RULES block.
It now sits at 1240 characters, leaving 808 of headroom.

That last cut was for **room**, not redundancy. Reflectors returned drafts 630-890 characters
longer than the 1839-character seed they were handed, so nearly every proposal broke the cap
and one run spent 8 of its 9 iterations re-scoring the instruction it started with. The rules
it dropped — never change a content word, preserve order and punctuation, leave a clean
transcript alone — are all properties the **score already enforces**, so they cost 597
characters to say what WER says for free. A seed that scores well and cannot be improved is
worth less than a slightly weaker one the search can build on; if those rules earn their
place, GEPA can put them back and the score will say so.

It plays three roles at once, which is what makes the run cheap to read:

- **`BASELINE`** — the bar a new search has to clear to be worth shipping, and what the winner
  is scored against on the held-out test split.
- **The default `--start`** — GEPA evolves from it, and because it fits the cap the search
  begins inside the feasible region rather than spending its first trials just getting legal.
- **An ordinary candidate** — scored in the sweep like any other, so it may simply win, and a
  run that fails to beat it costs nothing extra to discover.

What it is **not** is re-scored. Deletion cannot introduce wording the eval never saw, and the
three product-critical safeguards (don't answer, don't translate, don't rephrase) are asserted
present by `test_eval.py` — but whether the cut cost any cleanup quality is exactly the open
question the next run answers.

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

## Verifying on the model that actually runs it

Everything above scores a **stand-in**. `--model` answers the prompt and the search
optimises toward whatever it prefers, but the instruction ships to AssemblyAI's own rewrite
model, which we neither know nor select. Beating a stand-in is not evidence of beating the
real thing.

`--verify-live N` closes that loop. After a winner is picked it takes N **held-out** rows,
speaks the disfluent side with `say`, converts to 16 kHz mono PCM, and POSTs it to the real
`/transcribe` with the winner as `config.llm.instruction`:

```bash
export ASSEMBLYAI_API_KEY=...
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --verify-live 25 --verify-baseline
```

The response answers both halves at once. `text` is the verbatim transcript, so
`score(reference, text)` is the floor — what pasting with no rewrite would score.
`llm_response` is that transcript after the **real** rewrite model applied the instruction. The
gap is what the instruction bought.

`--verify-baseline` runs the same audio again with an empty `llm` block. That is the wording
Blurt ships today, so it is the comparison `guessed-default` could only ever guess at — the one
the README has flagged as unanswerable since this harness was written.

Read the **ranking, not the absolute scores**. Synthesised speech is not dictated speech,
`say` pronounces "um" as a word rather than producing a real hesitation, and the STT pass adds
its own errors before the rewrite runs. Every candidate hears the same audio, so comparisons
between them hold. macOS only, and off by default — it costs real transcription.

## Files

| File                         | What it holds                                                             |
| ---------------------------- | ------------------------------------------------------------------------- |
| `optimize_cleanup_prompt.py` | CLI, axis resolution, reporting.                                          |
| `candidates.py`              | The instructions under test, the character cap, and the GEPA seed.        |
| `corpus.py`                  | Sources, loading, de-tagging, splitting, the echo floor.                  |
| `disfluency.py`              | The seeded, additive disfluency injector.                                 |
| `metrics.py`                 | Token alignment, the two word-error-rate axes, GEPA feedback text.        |
| `live.py`                    | Synthesis + the real `/transcribe` round trip, for `--verify-live`.       |
| `program.py`                 | Everything that imports DSPy — the program, metrics adapters, optimizers. |
| `test_eval.py`               | Offline tests for injection, scoring, de-tagging, loading, and splitting. |

```bash
python3 -m pytest evals/dictation-prompt/test_eval.py
```

The tests need only `pytest` — they cover everything except the model calls, so they stay
green without a key.
