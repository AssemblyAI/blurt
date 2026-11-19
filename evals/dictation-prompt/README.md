# Dictation cleanup-prompt eval

A DSPy eval that searches for the best **cleanup instruction** for the dictation API's
LLM rewrite — the `config.llm` block Blurt sends on every `/v1/transcribe/live` request.

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

Each source supplies `(disfluent input, clean target)` pairs. The registered ones are
**real**: the disfluencies are the ones actual speakers produced, not ones we thought to
write down. A bare run loads **both** registered corpora (`--source nyra,voicearena`), and
they do different jobs: nyra is what the search learns from, Voice Arena is what decides
and reports the winner.

| `--source`             | What it is                                                                                                                                                                                                                                                                                    | Measures         |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| `nyra` (default)       | [`nyralabs/disfluency_speech_english`][nyra] — ~5k Switchboard utterances whose disfluencies trained annotators marked **by hand**, repackaged with casing repaired so the formatting axis is live. Costs some fidelity for that.                                                             | content + format |
| `voicearena` (default) | [`VoiceArena/Dictation_Dataset`][va] — the 151-clip public split of the [Voice Arena dictation benchmark][vab], which ranks Blurt against thirteen other Mac dictation tools. Real dictation (email, chat, notes, code, AI prompts) with recorded audio. **Dev and test only.** CC BY-NC 4.0. | content + format |
| `builtin`              | A dozen bundled sentences plus injection. No network, no key — for smoke-testing.                                                                                                                                                                                                             | content + format |

`--jsonl` reads a local file instead: objects with both `disfluent` and `reference` are used
as-is; anything with only a reference goes through the injector.

**Why keep synthetic injection at all**, now that real pairs exist? Mainly the **offline
path** — `--source builtin` needs no network and no key, which is what lets the test suite and
`--dry-run` verify the pipeline end to end. It also keeps a **severity dial** (`--severity`)
and a **punctuation-restoration** task (`--strip-formatting`) that the real corpus cannot pose,
though on a dozen bundled sentences those are smoke tests rather than measurements.

### How Voice Arena reaches the eval

Each clip ships `spoken_text` (the words as said) and `intended_text` (what should land on
the page), but the input side here is **neither**: it is the service's own verbatim
transcript of the recording, made once per clip through the buffered
`/v1/transcribe` route and cached at `~/.cache/blurt-evals/voicearena-stt.json`. The
first run needs `ASSEMBLYAI_API_KEY` for that; later runs make no calls.

The reason is that the rewrite never sees spoken forms. Measured 2026-11-18: the STT pass
already writes "sixty two thousand" as `$62,000`, "plan dot start date" as
`plan.startDate`, "version three" as `version 3`. Scoring `spoken_text` would hand the
stand-in inverse text normalization the production pipeline has already done. From the
STT transcript, what is left is the rewrite's real job — self-corrections ("over by
$7,000. Wait, no, the budget was $58,000"), restarts, hedges. On the same clips the
service's default rewrite left "Actually, no, the last 3 commits, not just one"
unresolved, which is the headroom this set exposes and nyra cannot: Switchboard has
almost no explicit self-corrections. `--voicearena-input spoken` uses `spoken_text`
instead; it needs no key, which is its only advantage.

**Why dev and test only.** `Source.held_out` puts these rows in dev and test, in the two
slices' proportion, before anything else, and only into train if both are full. The set
is there to judge the search. Training on it would let the reflector study the clips it is
later scored on, which is exactly what Voice Arena's own private split (608 clips) exists
to prevent. At default sizes that is 98 dev rows and 49 test rows, about 11% of each — the
selection is still mostly nyra. No word ceiling applies, so the long-form clips stay in.

The license is **non-commercial**. Loading it for internal evaluation is what this does;
nothing from it is redistributed or committed here.

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

It does not pose punctuation _restoration_, since both sides are already punctuated. Only
`--source builtin --strip-formatting` does, on a dozen bundled sentences.

[nyra]: https://huggingface.co/datasets/nyralabs/disfluency_speech_english
[va]: https://huggingface.co/datasets/VoiceArena/Dictation_Dataset
[vab]: https://voicearena.com/dictation-bench
[ds]: https://huggingface.co/datasets/amaai-lab/DisfluencySpeech
[dq]: https://huggingface.co/datasets/google-research-datasets/disfl_qa

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

There is one paired source, and that is not for want of looking. What the field offers is
mostly disfluency _detection_ corpora — per-token tags, not a clean rewrite — plus gated or
LDC-licensed sets. Two candidates were evaluated and rejected on measurement, not vibes.

Measured with no model involved: the corpus's disfluent side against its own target, the
median share of input words each asks to be deleted, and how much of that is filler.

| source                                        | no-cleanup floor | words deleted | of those, fillers | task           |
| --------------------------------------------- | ---------------- | ------------- | ----------------- | -------------- |
| **`nyra`**                                    | **0.789**        | 13%           | 67%               | remove fillers |
| [`amaai-lab/DisfluencySpeech`][ds] (upstream) | 0.834            | 11%           | 75%               | remove fillers |
| [`disfl-qa`][dq] — **removed**                | 0.435            | 31%           | **0%**            | something else |

`disfl-qa`'s floor of 0.435 looks like 3.4x the headroom and is not. It deletes 31% of the
input with **none of it filler**, and 11% of its targets contain words absent from the input,
so they cannot be reached by deletion at all. Its construction says why: Disfl-QA exists to
"serve as a benchmark dataset for testing robustness of models against disfluent inputs", and
annotators inserted a contextual disfluency into SQuAD questions "using the paragraph as a
source of distractors". In _"the second level of territorial division in **Poland** no make
that the basic unit of territorial division in **Warsaw**"_, "Poland" is not a speaker's slip —
it is a semantic decoy planted to see whether a QA model takes the bait. Deleting it is reading
comprehension. An instruction tuned there learns to discard content words, which is exactly
what `CleanupInstruction` forbids, so the source was removed rather than left as a trap.

What remains is close to saturated, and that is the honest ceiling on this harness. The shipped
instruction scores ~0.91 against a floor near 0.79–0.83, so it is worth roughly +0.08 and holds
about half of everything available. The gap between a good instruction and a great one is a few
thousandths — under the run-to-run noise — which is why two searches in a row could not beat
it. That is a property of the corpus, not a failure of the optimizer, and no search budget
resolves a difference smaller than the measurement.

### What the defaults do

A bare invocation is a full paid GEPA run, so it is worth knowing what it commits to.

| Default                                     | Why                                                                                                                                                                                                                                                               |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--model openai/qwen3.5-4b-32k-fast`        | The service's own rewrite runs under a ~5 s budget and is probably small, so a small stand-in is the faithful one. An instruction tuned against a frontier model can lean on comprehension the real one lacks. `openai/` is the wire protocol, not the vendor.    |
| `--api-base …llm-gateway.assemblyai.com/v1` | Where that model lives. Applies to the reflection model too. Pass `""` to use a provider's own endpoint.                                                                                                                                                          |
| `--reflection-model openai/claude-opus-4-8` | Deliberately not `--model`: a 4B model writing its own instructions is the weakest link in the loop. The `openai/` prefix is LiteLLM routing, stripped before the gateway sees it.                                                                                |
| `--optimizer gepa` · `--start prior-winner` | Evolve from `candidates.PRIOR_WINNER` — the strongest instruction we have, and `BASELINE` — rather than restarting from a four-line candidate that knows none of what it learned. It fits the cap, so the search starts inside the feasible region.               |
| `--auto heavy`                              | 27 reflection trials (light is 10, medium 18). This is the **only** knob that changes how many ideas get tried — corpus size does not. Merge is off: crossover needs more than one predictor, so it would only re-evaluate duplicates.                            |
| `--source nyra,voicearena` · `--limit 4000` | Each source reads its own split — nyra's 4458-row `train`, Voice Arena's only split, `test` — and `--limit` applies per source. Voice Arena goes to dev and test; everything else past them becomes train, and train rows are free — see below.                   |
| `--dev-fraction 900` (rows, not a fraction) | Dev decides which instruction ships — `BASELINE` versus the optimizer's result — and the optimizer never sees it. Sized for **resolution**: see below.                                                                                                            |
| `--gepa-valset 450` (rows)                  | The optimizer's own valset, carved off train. Every surviving candidate is scored against all of it, so its size multiplies search cost while buying no exploration — that is `--auto` alone. Raised for the same reason as dev.                                  |
| `--reflection-minibatch-size 8`             | Scored examples the reflector sees before rewriting. GEPA's default is 3, which on a task this well-solved is often three near-perfect examples and almost no failure to generalise from.                                                                         |
| `--test-fraction 450` (rows)                | The honest number, from data no selection step saw. Scored twice at the end.                                                                                                                                                                                      |
| `--candidates baseline`                     | A search run scores only `BASELINE` on dev — it is the bar, the fallback and the seed at once, so the other six cost a dev sweep each to re-rank instructions the search never uses. `--optimizer none` scores all of them, since there the ranking is the point. |
| `--num-threads 1`                           | The gateway rate-limits; a 429 storm mid-run costs more wall-clock than the concurrency saves. Raise it for a provider that tolerates it.                                                                                                                         |
| `--max-tokens 8192`                         | Headroom for reasoning tokens, not for the answer. Truncation here is silently corrupting — see below.                                                                                                                                                            |

That leaves **train 2200 / optimizer valset 450 / dev 900 / test 450**, for roughly 8,700 model
calls: 900 to score `BASELINE`, ~6,000 for the search, 900 to re-score its result, and 900 for
the two held-out scorings at the end. At `--num-threads 1` that is a few hours; raise it if the
gateway tolerates the parallelism.

**Why the two evaluation sets are this large.** The binding constraint on finding a winner is
not search budget, it is measurement. A search once beat the seed by +0.008 on a 50-row valset
and lost to it by 0.006 on a 150-row dev split — both differences inside the run-to-run noise,
so the run spent 27 reflection trials producing a number that could not be trusted either way.
A later `--auto heavy` run landed 0.001 behind its seed on 300 dev rows, which is the same
non-answer at three times the cost. More trials sample the same noise more often; more rows
shrink it — as the square root, so the 3x here is worth about 42% of it, and nothing cheaper
buys any. Raising the valset also
matters on its own, because GEPA's Pareto front ranks candidates per validation example, and at
50 rows it was ordering them on differences it could not resolve — then handing dev a winner
dev rejected.

This does not make a winner exist. It makes a real one detectable and a spurious one rejected,
which are the two outcomes worth paying for.

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

**Truncation poisons a run rather than failing it.** The plain adapter means the whole
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
environment. With plain `pip`, `pip install "dspy>=3.0,<3.5"` is the only requirement. The cap is
deliberate: DSPy 3.5.0 reworked its LM layer, and every `openai/` model call through the LLM Gateway
then fails with "Not found".

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

The plain adapter — now the only one — sends the candidate instruction as the system message and the
transcript as the user message, and takes the whole reply as the cleaned text. That is the
shape the service applies `config.llm_instruction` in: one instruction, one transcript, one
pass, no envelope.

DSPy's own `ChatAdapter`, which was selectable as `--adapter chat` and has been removed,
instead wraps both sides in `[[ ## field ## ]]`
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
| `--source`           | `nyra,voicearena`            | Which corpora to score against, comma-separated — see the table above.                                 |
| `--voicearena-input` | `stt`                        | Voice Arena's input side: the service's cached STT transcript, or `spoken` for the dataset's own.      |
| `--model`            | `openai/qwen3.5-4b-32k-fast` | The LiteLLM model standing in for the service's rewrite model.                                         |
| `--reflection-model` | `openai/claude-opus-4-8`     | Writes the instructions during `--optimizer gepa`. Keep it stronger than `--model`.                    |
| `--api-base`         | the AssemblyAI gateway       | Endpoint for both models. `""` falls back to the provider's own.                                       |
| `--metric`           | `blend`                      | `content` (words only), `format` (case and punctuation too), or 0.7/0.3 of both.                       |
| `--severity`         | `0.35`                       | 0–1; how often a disfluency is injected. Reference-only sources only.                                  |
| `--strip-formatting` | off                          | Also lowercase and unpunctuate, so restoring formatting is part of the task.                           |
| `--optimizer`        | `gepa`                       | `none` only ranks the candidates; both optimizers search instructions only.                            |
| `--start`            | `prior-winner`               | Which instruction GEPA evolves from — the compressed prior winner, or the best hand-written candidate. |
| `--auto`             | `heavy`                      | Reflection trials: 10 / 18 / 27. The only knob that changes how many ideas get tried.                  |
| `--split`            | each source's own            | Overrides the split read from every source. nyra defaults to `train`, Voice Arena to `test`.           |
| `--limit`            | `2000`                       | Rows loaded, then sliced 1800 train / 50 dev / 150 test. Train rows cost nothing.                      |
| `--dev-fraction`     | `150` (rows)                 | Fraction below 1, absolute count at 1 or above. Decides what ships; the search never sees it.          |
| `--gepa-valset`      | `50` (rows)                  | The optimizer's valset, taken off train. Multiplies search cost, adds no exploration.                  |
| `--test-fraction`    | `150` (rows)                 | Same convention. Scored twice, and by nothing that makes a selection.                                  |
| `--num-threads`      | `1`                          | Serial by default — the gateway rate-limits.                                                           |
| `--max-tokens`       | `8192`                       | Headroom for reasoning tokens. Too low silently corrupts a run rather than failing it.                 |
| `--seed`             | `7`                          | Seeds injection and the train/dev/test split.                                                          |

Both optimizers run with few-shot demos disabled. `config.llm_instruction` is a single string
the service applies in one pass, so an optimized program that depended on bundled examples
would score well here and be unshippable.

## What this can and cannot establish

The harness is deliberately text-only: a transcript goes in, an instruction transforms it, the
output is scored against the target. That keeps it cheap, fast, and reproducible, and it is the
right shape for ranking instructions against each other.

It does not measure the thing we ship as a _default_. Blurt sends its own
`config.llm_instruction` (`CleanupInstruction.text`); a request that omits the field applies **the
service's own default cleanup instruction, on the service's own rewrite model** — neither of
which we know. The `guessed-default` candidate is a guess at the first and ignores the second,
and is named that way on purpose. Treat a win over it as "this instruction is better than a
terse one on our stand-in model", not as "this beats what we ship".

Two consequences worth holding onto when reading a result:

- A winner is only as transferable as `--model` is representative of the service's rewrite
  model, which runs under a ~5s budget and is probably much smaller.
- Confirming a win against the live default means sending real audio to
  `dictation.assemblyai.com/v1/transcribe/live` with the instruction omitted and comparing. That is
  `--verify-live --verify-baseline`, and for the current winner it has been done — see
  [Verifying on the model that actually runs it](#verifying-on-the-model-that-actually-runs-it).
  It is a separate measurement from everything above, not a property of these scores.

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

### False starts are not charged like fillers

One departure from plain WER, and the reason a run reports what share of its rows contain a
false start. **A word of an abandoned span left in the output costs
`metrics.FALSE_START_WEIGHT` errors (5) rather than one.**

Flat WER made "um" and an abandoned clause worth the same, and the arithmetic then told the
search to ignore the abandoned clause. Over 400 `nyra` rows, 15.0% of the input words have to
be deleted, and only 3.7% of them are abandoned spans — a quarter of the surplus, sitting in
20% of the rows at a mean of 4.1 words each. Ignoring false starts entirely cost about 0.04 of
content score; rival instructions are separated by nearer 0.01. So the cheapest way to win was
to polish filler removal, which is the disfluency the rewrite models already handle, and to
leave alone the one they don't. The failures also aren't comparable: a leftover "um" reads as a
typo, while `we wouldn't ha-` surviving in front of `we wouldn't have them` pastes a sentence
the user never said.

An abandoned span is found from the pair, not from an annotation — no corpus here labels
reparanda. Align what was spoken against what was intended, and whatever the speaker said that
the target does not contain is surplus; a _run_ of surplus counts as abandoned when it holds a
**cut-off word** (`th-`, `ha-`, `store—`) or is **two or more non-hesitation words** that
aren't a verbatim echo of the span beside them. So `it was it was really bad` stays a stammer,
`you know` and `okay so` stay hedges, and `and they th- their tax deal` is charged at three.
The cut-off signal is free: `_detag_nyra` already rewrites Switchboard's `th*` convention into
`th-`, and the injector emits the same shape. On those 400 rows the rule fires on 80, and the
no-cleanup floor moves from 0.797 to 0.658.

Two consequences worth keeping in mind. `metrics.score` needs the **input** as well as the
target, since nothing about a leftover word says whether it was abandoned — `corpus.Utterance`
carries both sides for exactly that reason. And numbers either side of a change to
`FALSE_START_WEIGHT` are not comparable; 1.0 restores plain WER.

All three axes are printed for every candidate, with the selecting one starred, so you can
see whether a winner gained on wording or only on punctuation. The winner is chosen on a dev
split and re-scored on a held-out test split alongside `BASELINE` — `prior-winner`, the best
instruction we already have — so the reported improvement is measured on data no selection
decision touched, against the thing a new instruction would actually replace.

On `nyra` the numbers mean what they say. On `builtin` the disfluencies are synthetic, so the
**ranking** travels further than the absolute scores do: read those as
"this instruction beats that one on this disfluency distribution", and re-run at a couple of
`--severity` values before trusting an ordering.

## Applying a winner

**The app ships one instruction per rewrite mode**, and each is a candidate here:
`prior-winner` is Fast's (`CleanupInstruction.text`), `smart-winner` is Smart's
(`CleanupInstruction.smartText`), and `test_eval.py` checks both against the Swift literals byte
for byte. A run's `--baseline` should match its `--model`: `--model openai/gemma-4-31b
--baseline smart-winner` for Smart, the defaults for Fast. A prompt tuned for one mode has
measured worse on the other, so a winner replaces only its own mode's instruction.

The winning string goes into the request's `config.llm_instruction`, next to the `prompt`
field that steers transcription. The Swift side is
`Sources/BlurtEngine/STT/AssemblyAITranscriber.swift`, where the field is an optional
string — omitting it is what selects the service default.

Store it **verbatim**, exactly as the run emitted it. The harness scores instructions through
the same envelope the service applies them in (see the plain adapter), so the string
as-emitted is the string that was measured; a hand-tidied copy is an unscored string that
looks scored.

### No length cap

`config.llm_instruction` used to accept at most **2048 characters** — HTTP 400, _"llm_instruction:
String should have at most 2048 characters"_, measured 2026-08-11 — and a 3057-character GEPA
winner once shipped over it and broke all dictation. Most of this harness's search machinery
existed to stay under it: a soft target below the cap, budgets restated in words and
sentences, a re-ask on every over-long proposal, a section-dropping trim, a pre-flight
check, and a refusal at selection.

**That cap is gone.** Re-probed 2026-11-18 against the live route in both rewrite modes —
Fast (no `rewrite_mode`) and `"smart"` — with instructions of 2049, 4096, 8192, 16384,
32768 and 49152 characters: every one returned 200 and rewrote correctly. The only limit
left is on the whole `config` JSON part, 64 KiB (400 _"`config` part too large"_), which no
reflector comes near. So all of the length machinery has been removed and the search may
write as long an instruction as scores best.

**The app followed.** `CleanupInstruction` on the Swift side has no cap either, so a longer
winner ships as-is. A user's style profile is appended to it, trimmed to its own editor limit
(`StyleProfileStore.characterLimit`, 4000 UTF-8 bytes), which keeps a full request far below the
64 KiB `config` limit.

### The safeguards the corpus cannot defend

`PRIOR_WINNER` forbids answering the transcript and forbids translating it. Those clauses are
why dictating "what time is it?" pastes the question instead of an answer, and why non-English
speech survives as spoken. **Nothing in the scoring can see either property**: every corpus
here is English, and none punishes an answer to a dictated question, so an instruction that
drops them scores exactly the same. Dropping them is what a well-behaved optimizer _should_ do
given what it can see. (Voice Arena does contain dictated questions — 43 of 151 — so a model
that answered them would now lose WER, but nothing checks translation.)

So they are gated rather than measured, by the `objections` mechanism:
the proposer rejects and re-asks, and selection refuses a winner without them. Matching is on
stems (`answer`, `translat`), so any phrasing passes — a false accept is far cheaper than a
false reject that burns retries on a good instruction.

"Do not rephrase" is deliberately **not** gated. Substituting a content word raises WER
directly, so the score already defends that one. The gate is only for what nothing else sees.

`program.GatedInstructionProposer` is GEPA's documented `instruction_proposer` hook. It
delegates to GEPA's own reflection prompt, then rejects any proposal that drops a safeguard,
names a DSPy field, or copies the constraints block, and re-asks against the rejected draft.
After five tries it returns the instruction **unchanged** rather than a hand-patched one. The
same `objections` check refuses an optimizer result at selection, however well it scored.

### Why the proposer also rejects field names

The harness's DSPy signature is `raw_transcript -> cleaned_transcript`, and GEPA's reflective
dataset is **keyed by those field names** — so the reflection model sees them as labels and
writes instructions that refer to them ("output the result as `cleaned_transcript`").

Those fields exist in neither envelope. `PlainChatAdapter` sends the bare transcript as the
user turn and the instruction as the system message, with no field scaffolding; the service
does the same. So the instruction describes a message the model never receives — and worse, it
invites the model to emit the label literally, which Blurt would paste into the user's
document. The eval is structurally unable to catch that: under the plain adapter the whole
completion is the answer, so if the small stand-in doesn't take the bait where the service's
rewrite model does, the score looks fine.

The leak regenerates every run, which is why it is a gate rather than a one-time fix. Both
faults are reported in the same re-ask, so one revision round fixes everything rather than
surfacing the next fault a round later.

**Nothing is exempt, `prior-winner` included.** It passes the same pre-flight safeguard check
as everything else, and if a later edit strips one, the run stops before spending anything.

### `prior-winner`, and how it got under the (former) cap

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
- **The default `--start`** — GEPA evolves from it. It was cut down to leave the search room
  under the old cap; with the cap gone, the search is free to put back what was cut.
- **An ordinary candidate** — scored in the sweep like any other, so it may simply win, and a
  run that fails to beat it costs nothing extra to discover.

What it is **not** is re-scored. Deletion cannot introduce wording the eval never saw, and the
three product-critical safeguards (don't answer, don't translate, don't rephrase) are asserted
present by `test_eval.py` — but whether the cut cost any cleanup quality is exactly the open
question the next run answers.

Three things to keep straight, all settled decisions in
[`AGENTS.md`](../../AGENTS.md#settled-decisions--dont-reintroduce-these):

- This is the **server-side** rewrite instruction. It is not a client-side cleanup pass, and
  the winning string is not a transcription-steering change — `config.stt_prompt`
  (`STTPrompt`) steers transcription and carries no instructions at all, because
  disfluency removal is this rewrite's job.
- The positive-phrasing guidance that used to shape the transcription prompt comes from
  AssemblyAI's Universal-3 prompting reference and applies to the STT model. That prompt exists
  again as `config.stt_prompt` (the same field renamed), but it carries prior text and no
  instructions — while the cleanup instruction here is read by an ordinary LLM, so these
  candidates are phrased as plain instructions.
- **Every corpus here is English, and the prompt is not.** `config.llm_instruction` ships to
  every user in every language, and pinning the transcription prompt to English was reverted
  once already for hurting non-English transcription. A winner selected on this harness has
  only been shown to work in English; weigh that before shipping a long, English-shaped
  instruction.

## Verifying on the model that actually runs it

Everything above scores a **stand-in**. `--model` answers the prompt and the search
optimises toward whatever it prefers, but the instruction ships to AssemblyAI's own rewrite
model, which we neither know nor select. Beating a stand-in is not evidence of beating the
real thing.

`--verify-live N` closes that loop. After a winner is picked it takes N **held-out** rows and
POSTs their audio to the real `/v1/transcribe/live` with the winner as `config.llm_instruction`.
Voice Arena rows come first in the test slice and are played **as recorded** — real people
dictating — converted to 16 kHz mono PCM. Only rows without a recording fall back to speaking
the disfluent side with `say`. `--rewrite-mode smart` asks for the larger rewrite model, as the
app's Smart setting does; the dictation docs recommend Smart whenever `llm_instruction` is set.

```bash
export ASSEMBLYAI_API_KEY=...
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --verify-live 25 --verify-baseline
```

The response answers both halves at once. `text` is the verbatim transcript, so
`score(reference, text)` is the floor — what pasting with no rewrite would score.
`llm_response` is that transcript after the **real** rewrite model applied the instruction. The
gap is what the instruction bought.

### What it said about the shipped instruction

Twenty held-out utterances, same synthesized audio for every arm, no rewrite failures:

| instruction                            | delivered  | gain over no rewrite |
| -------------------------------------- | ---------- | -------------------- |
| _(no rewrite at all — the floor)_      | 0.3365     | —                    |
| service default (no instruction)       | 0.3561     | +0.0196              |
| the instruction before the current one | 0.3608     | +0.0243              |
| **`prior-winner` as it ships today**   | **0.4107** | **+0.0742**          |

That settles the question this section exists to ask, in both directions. Read the **gain**
column, not the delivered score: the transcript is already there, so the instruction's whole job
is the delta above the floor, and both arms start from a byte-identical transcript. On that
measure the shipped instruction adds **+0.0498 more than its predecessor** — 3.1x as much
improvement, though a ratio of two small numbers on twenty rows is the fragile way to say it.
It is also the first instruction here measured **above the service's own default wording**
rather than assumed to be — the harness had never been able to say that. Note the ordering also survived the trip from
the stand-in, where the same pair differed by only +0.0134: a text-harness win of that size did
transfer, and grew.

It is twenty rows of synthesized speech, so read the ranking rather than the numbers. The
sampled outputs are worth reading too — they are what showed that the instruction's aggressive
deletion of a leading "yeah" / "well" is _earning_ the gain rather than over-editing, which is
the opposite of what was expected of that clause and is not visible in a mean.

`--verify-baseline` runs the same audio again with the instruction omitted. That is the wording
Blurt ships today, so it is the comparison `guessed-default` could only ever guess at — the one
the README has flagged as unanswerable since this harness was written.

For rows played with `say`, read the **ranking, not the absolute scores**. Synthesised speech is not dictated speech,
`say` pronounces "um" as a word rather than producing a real hesitation, and the STT pass adds
its own errors before the rewrite runs. Every candidate hears the same audio, so comparisons
between them hold. macOS only, and off by default — it costs real transcription.

## Files

| File                         | What it holds                                                                                                       |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `optimize_cleanup_prompt.py` | CLI, axis resolution, reporting.                                                                                    |
| `candidates.py`              | The instructions under test, the shippability gate, and the GEPA seed.                                              |
| `corpus.py`                  | Sources, loading, de-tagging, splitting, the echo floor.                                                            |
| `voicearena.py`              | Voice Arena's input side: the service's STT transcript per clip, fetched once and cached.                           |
| `voicearena_baseline.py`     | Blurt on the Voice Arena public set as the leaderboard scores it (`amend-va` judge), per-stage failure attribution. |
| `disfluency.py`              | The seeded, additive disfluency injector.                                                                           |
| `metrics.py`                 | Token alignment, the two word-error-rate axes, the false-start surcharge, GEPA feedback text.                       |
| `live.py`                    | Recorded or synthesized audio + the real `/v1/transcribe/live` round trip, for `--verify-live`.                     |
| `program.py`                 | Everything that imports DSPy — the program, metrics adapters, optimizers.                                           |
| `test_eval.py`               | Offline tests for injection, scoring, de-tagging, loading, and splitting.                                           |

```bash
python3 -m pytest evals/dictation-prompt/test_eval.py
```

The tests need only `pytest` — they cover everything except the model calls, so they stay
green without a key.
