#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["dspy>=3.0"]
# ///
"""Find the best cleanup instruction for Blurt's dictation request.

What this optimizes
-------------------
Blurt sends one `POST /transcribe` per utterance. The request's `config.prompt`
steers *transcription*; the `config.llm` block asks the service to run an LLM
rewrite over the verbatim transcript — that rewrite is what removes disfluencies
and fixes punctuation before the text is pasted. Blurt currently sends `llm` as an
empty object, which selects the service's default cleanup instruction. This script
searches for an explicit instruction that beats that default, so `llm.instruction`
can be set deliberately rather than left to the server.

How it measures that
--------------------
By default it uses a **real paired corpus**: `amaai-lab/DisfluencySpeech`, which
ships each utterance twice — as the speaker said it and as they meant it — from
Switchboard conversations whose disfluencies trained annotators marked by hand.
Candidates are scored on how closely their output restores the intended side
(`metrics.py`). `--source` selects other corpora, including `fleurs`, where clean
read speech is made disfluent synthetically (`disfluency.py`) — the only mode with
a severity dial and the only one that can pose punctuation restoration as a task.
See `corpus.py` for what each source can and cannot measure.

Usage
-----
    # The defaults are a full GEPA run: 500 train rows through a small model behind
    # the AssemblyAI LLM Gateway, pruning candidates.PRIOR_WINNER under the character
    # cap, with a frontier model doing the reflection. Nothing needs passing.
    export OPENAI_API_KEY=$ASSEMBLYAI_API_KEY
    uv run evals/dictation-prompt/optimize_cleanup_prompt.py

    # Cheap sanity check first: rank the hand-written candidates, no search.
    uv run evals/dictation-prompt/optimize_cleanup_prompt.py --optimizer none --limit 100

    # No network and no API key — checks the pipeline end to end.
    python3 evals/dictation-prompt/optimize_cleanup_prompt.py --source builtin --dry-run

    # Against a frontier model on its own endpoint instead of the gateway.
    ANTHROPIC_API_KEY=... uv run evals/dictation-prompt/optimize_cleanup_prompt.py \
      --model anthropic/claude-opus-5 --api-base "" --reflection-model anthropic/claude-opus-5

The length constraint
---------------------
`config.llm.instruction` is capped at `candidates.INSTRUCTION_CHARACTER_CAP`
characters and an instruction over it fails the whole request, so a winner that
doesn't fit isn't a winner. Four places enforce that, because none is sufficient
alone: the hand-written candidates are checked before any model call; the cap is
stated to GEPA's reflector in the feedback text, which is guidance it can ignore;
`program.CappedInstructionProposer` rejects and re-asks any over-cap proposal
before GEPA scores it, which is what makes the cap a constraint on the *search*
rather than a verdict on its output; and an over-cap result is refused at selection
no matter how well it scored. Only GEPA has the proposal hook — under
`--optimizer mipro` the search is unconstrained and only the last one applies.

`--dry-run` and the tests need no third-party packages: everything that touches
DSPy lives in `program.py`, which is imported only after the dry-run returns.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import corpus  # noqa: E402
import metrics  # noqa: E402
from candidates import (  # noqa: E402
    BASELINE,
    CANDIDATES,
    INSTRUCTION_CHARACTER_CAP,
    missing_safeguards,
    objections,
    overage,
)
from progress import Progress  # noqa: E402


def print_table(rows: list[tuple[str, dict[str, float]]], title: str, axis: str) -> None:
    """Every axis, with the selecting one marked so a blended winner stays legible."""
    print(f"\n{title}")
    header = "  ".join(f"{name + ' *' if name == axis else name:>9}" for name in metrics.AXES)
    print(f"  {'candidate':<22} {header}")
    print(f"  {'-' * 22} {'  '.join(['-' * 9] * len(metrics.AXES))}")
    for name, scores in sorted(rows, key=lambda row: row[1][axis], reverse=True):
        print(f"  {name:<22} " + "  ".join(f"{scores[a]:>9.4f}" for a in metrics.AXES))


def print_samples(loaded: corpus.Corpus, count: int) -> None:
    print(f"\nExamples (showing {min(count, len(loaded))} of {len(loaded)})")
    for utterance in loaded.utterances[:count]:
        floor = metrics.score(utterance.reference, utterance.disfluent)
        print(f"\n  input    : {utterance.disfluent}")
        print(f"  target   : {utterance.reference}")
        if utterance.operations:
            print(f"  injected : {', '.join(utterance.operations)}")
        print(f"  uncleaned: content {floor.content:.3f} / format {floor.format:.3f}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    data = parser.add_argument_group("corpus")
    data.add_argument(
        "--source",
        default="disfluency-speech",
        choices=(*corpus.SOURCES, "builtin"),
        help="which corpus to score against (default: hand-annotated Switchboard pairs)",
    )
    data.add_argument(
        "--loader",
        default="datasets-server",
        choices=("datasets-server", "datasets"),
        help="datasets-server is the HTTP rows API; datasets uses the library (gated sets)",
    )
    data.add_argument(
        "--limit",
        type=int,
        default=2000,
        help="how many pairs to load (default: 2000). Everything past --dev-fraction and "
        "--test-fraction becomes train, and train rows are the free ones: GEPA draws a "
        "fixed number of fixed-size reflection minibatches however large the trainset is, "
        "so raising this buys more varied feedback at no extra model cost. The ceiling is "
        "the corpus (disfluency-speech is ~5k utterances) and the datasets-server rate "
        "limit, not the budget — set HF_TOKEN for a large load",
    )
    data.add_argument(
        "--split",
        default="train",
        help="dataset split to read (default: train). Each source's own default is its "
        "held-out split, which is only ~250 rows — too few for the default --limit, and "
        "too few to leave a large trainset after the dev/test slices. Pass --split test "
        "to read a source's held-out rows instead",
    )
    data.add_argument("--jsonl", help="load pairs (or bare references) from a local .jsonl")

    injection = parser.add_argument_group("synthetic injection (reference-only sources)")
    injection.add_argument("--seed", type=int, default=7)
    injection.add_argument(
        "--severity",
        type=float,
        default=0.35,
        help="0..1; scales how often a disfluency is injected (default: 0.35)",
    )
    injection.add_argument(
        "--strip-formatting",
        action="store_true",
        help="also lowercase and unpunctuate, making formatting restoration part of the task",
    )

    evaluation = parser.add_argument_group("evaluation")
    evaluation.add_argument(
        "--metric",
        default="blend",
        choices=metrics.AXES,
        help="which axis selects the winner (default: blend, 0.7 content / 0.3 format)",
    )
    evaluation.add_argument(
        "--dev-fraction",
        type=float,
        default=150,
        metavar="ROWS_OR_FRACTION",
        help="dev rows, absolute at 1 or above and a fraction below (default: 150). Dev "
        "decides which instruction ships — baseline versus the optimizer's result — and "
        "the optimizer never sees it: its own valset is carved from train instead "
        "(--gepa-valset). Sized for a decision you can trust rather than for the search",
    )
    evaluation.add_argument(
        "--gepa-valset",
        type=float,
        default=50,
        metavar="ROWS_OR_FRACTION",
        help="rows taken off train for the optimizer's own valset (default: 50). GEPA "
        "scores every surviving candidate against all of it, so its size multiplies the "
        "search's cost while buying no extra exploration — that depends only on --auto. "
        "GEPA's own advice is the smallest set that still matches the task distribution",
    )
    evaluation.add_argument(
        "--test-fraction",
        type=float,
        default=150,
        metavar="ROWS_OR_FRACTION",
        help="held-out rows, absolute at 1 or above and a fraction below (default: 150). "
        "Scored twice at the end, for the winner and the baseline; no selection step sees "
        "it, so this is the honest number",
    )
    evaluation.add_argument(
        "--num-threads",
        type=int,
        default=1,
        help="concurrent model calls (default: 1). Serial by default because the LLM "
        "Gateway rate-limits, and a 429 storm mid-run costs more wall-clock than the "
        "concurrency saves; raise it for a provider that tolerates the parallelism",
    )
    evaluation.add_argument(
        "--dry-run",
        action="store_true",
        help="build and score the corpus without calling any model",
    )
    evaluation.add_argument(
        "--reflection-minibatch-size",
        type=int,
        default=8,
        help="scored examples the reflector sees before rewriting the instruction "
        "(default: 8). GEPA's own default is 3, which on a task this well-solved is "
        "often three near-perfect examples and almost no failure to generalise from. "
        "Cheap next to the periodic full-valset evals",
    )
    evaluation.add_argument(
        "--candidates",
        default=None,
        choices=("baseline", "all"),
        help="which candidates to score on dev before searching. Default: baseline only "
        "for a search run (it is the bar, the fallback, and the seed — the rest cost "
        "len(CANDIDATES) x dev calls to re-rank instructions the search will not use), "
        "and all of them under --optimizer none, where the ranking is the whole point",
    )
    evaluation.add_argument("--show-samples", type=int, default=3)

    model = parser.add_argument_group("model")
    model.add_argument(
        "--model",
        default="openai/qwen3.5-4b-32k-fast",
        help="LiteLLM model id standing in for the service's rewrite model. Defaults to a "
        "small model behind the AssemblyAI LLM Gateway because the service's own rewrite "
        "runs under a ~5s budget and is probably small too — an instruction tuned against "
        "a frontier model can rely on comprehension the real one lacks. `openai/` selects "
        "the wire protocol, not the vendor: the gateway is OpenAI-compatible, so this "
        "reads OPENAI_API_KEY (set it to your AssemblyAI key)",
    )
    model.add_argument(
        "--reflection-model",
        default="openai/claude-opus-4-8",
        help="model that rewrites instructions during --optimizer gepa. Deliberately NOT "
        "the default --model: a 4B model writing its own instructions is the weakest link "
        "in the loop. Pass the same id as --model to collapse them",
    )
    model.add_argument(
        "--api-base",
        default="https://llm-gateway.assemblyai.com/v1",
        help="API base URL for both --model and --reflection-model (default: the "
        "AssemblyAI LLM Gateway). Pass an empty string to use the provider's own endpoint, "
        "e.g. with --model anthropic/claude-opus-5",
    )
    model.add_argument(
        "--max-tokens",
        type=int,
        default=8192,
        help="output ceiling for the task model (default: 8192). A cleaned transcript is a "
        "sentence or two, so this is not sized for the answer — it is headroom for reasoning "
        "tokens, which count against the same budget. Truncation here is silently corrupting "
        "rather than loud: see ModelSpec.max_tokens",
    )
    model.add_argument(
        "--temperature",
        type=float,
        default=None,
        help="sampling temperature for the task model only (default: unset, provider "
        "decides). Reach for it when the task model truncates at --max-tokens: a cleaned "
        "transcript is a sentence or two, so hitting the ceiling means a repetition loop, "
        "and the loop gets scored as the cleanup. Not applied to the reflection model, "
        "which is normally a Claude one and rejects an explicit temperature",
    )
    model.add_argument(
        "--reflection-max-tokens",
        type=int,
        default=65536,
        help="output ceiling for the reflection model (default: 65536). Much larger than "
        "--max-tokens because this model thinks at length before writing an instruction, and "
        "extended thinking counts against the same budget. Kept separate so a frontier "
        "reflector's headroom is not demanded of a small task model on a 32k context",
    )
    model.add_argument(
        "--adapter",
        default="plain",
        choices=("plain", "chat"),
        help="plain sends the instruction and transcript as a bare chat turn, the way the "
        "service applies config.llm.instruction; chat uses DSPy's field-marker protocol, "
        "which small models cannot follow",
    )

    search = parser.add_argument_group("search")
    search.add_argument(
        "--optimizer",
        default="gepa",
        choices=("none", "gepa", "mipro"),
        help="gepa (default) evolves a new instruction from --start; none only ranks the "
        "built-in candidates, which is the cheap way to sanity-check a corpus or a model "
        "before paying for a search",
    )
    search.add_argument(
        "--auto",
        default="heavy",
        choices=("light", "medium", "heavy"),
        help="optimizer search budget (default: heavy). This is the knob that decides how "
        "many ideas get tried — 10 reflection trials at light, 18 at medium, 27 at heavy, "
        "independent of corpus size. Shrinking --gepa-valset makes each trial cheaper; "
        "only this makes there be more of them",
    )
    search.add_argument(
        "--start",
        default="prior-winner",
        choices=("prior-winner", "best-candidate"),
        help="which instruction the optimizer starts from (default: prior-winner, the "
        "evolved instruction in candidates.py — it already scores well and only needs "
        "pruning under the character cap; best-candidate starts from whichever "
        "hand-written candidate topped dev instead)",
    )

    live_group = parser.add_argument_group("live verification (macOS, real endpoint)")
    live_group.add_argument(
        "--verify-live",
        type=int,
        default=0,
        metavar="N",
        help="after picking a winner, run N held-out utterances through the REAL dictation "
        "API — synthesized to audio with `say`, then POSTed with the winner as "
        "config.llm.instruction. The only measurement here that uses the rewrite model "
        "the instruction actually ships to; everything else scores a stand-in. Needs "
        "ASSEMBLYAI_API_KEY and a Mac. 0 disables",
    )
    live_group.add_argument(
        "--verify-baseline",
        action="store_true",
        help="also run the same audio with an empty llm block, which is what Blurt sends "
        "today. This is the comparison the text harness cannot make: guessed-default only "
        "ever guessed at the service's default wording, and this uses the wording itself",
    )

    parser.add_argument("--out", default=None, help="write the full results as JSON to this path")
    return parser.parse_args(argv)


def describe_length(instruction: str) -> str:
    """`2048 chars` plus how that sits against the cap — the line every report ends on."""
    over = overage(instruction)
    if over:
        return f"{len(instruction)} chars — {over} OVER the {INSTRUCTION_CHARACTER_CAP} cap"
    headroom = INSTRUCTION_CHARACTER_CAP - len(instruction)
    return f"{len(instruction)} chars, {headroom} under the {INSTRUCTION_CHARACTER_CAP} cap"


def check_candidates() -> None:
    """Refuse to start if a hand-written candidate could never be shipped.

    Before any model call, because these are typo-class mistakes and paying for a full
    sweep to discover one is pure waste. Nothing is exempt, `prior-winner` included:
    it earned its place in the table by being compressed under the cap, and if a later
    edit pushes it back over — or strips a safeguard — this is what says so.

    Only `BASELINE` is held to the safeguard requirement. The other candidates are
    deliberately terse one-liners whose job is to be *contrast* — `guessed-default` is
    a floor, not something anyone would ship — and demanding the full safeguard set of
    them would turn the comparison set into six copies of the same careful paragraph.
    """
    problems: list[str] = []
    for name, text in CANDIDATES.items():
        if overage(text):
            problems.append(f"  {name}: {describe_length(text)}")
        if name == BASELINE and (absent := missing_safeguards(text)):
            stems = ", ".join(stem for stem, _ in absent)
            problems.append(f"  {name}: BASELINE is missing safeguard(s): {stems}")
    if problems:
        raise SystemExit(
            "These candidates.py instructions could not be shipped as written:\n"
            + "\n".join(problems)
        )


def resolve_candidates(args: argparse.Namespace) -> list[str]:
    """Which candidates get scored on dev before the search.

    Sweeping all of them costs `len(CANDIDATES) × dev` calls to re-establish an
    ordering that mostly does not change, so a search run scores only what it needs:
    `BASELINE`, which is simultaneously the bar the optimized instruction must clear,
    the fallback if it doesn't, and — under the default `--start` — the seed. Its
    score against the no-cleanup floor is also the setup check the full sweep used to
    provide: an instruction this strong landing near the floor means the model or the
    corpus is wrong, not the instruction.

    A run that isn't searching gets the full table, because ranking one candidate is
    not a ranking. That is the shape of `--optimizer none`: the cheap pass you make
    when you have changed the corpus or the model and want the ordering itself.
    """
    if args.candidates == "all" or (args.candidates is None and args.optimizer == "none"):
        return list(CANDIDATES)
    # BASELINE first: it is the row every later comparison is stated against.
    ordered = [BASELINE]
    if args.start == "best-candidate":
        # Nothing has been scored yet, so "best" is unknowable without the sweep.
        return list(CANDIDATES)
    return ordered


def run_live_verification(
    args: argparse.Namespace,
    winner_name: str,
    winner_instruction: str,
    test: list[corpus.Utterance],
) -> dict[str, dict[str, float]] | None:
    """Score the winner on the rewrite model it will actually ship to.

    Held-out rows on purpose: this is a check on the result, not another selection
    step, and running it on data the search saw would only re-report the search.

    Deferred import and a caught `Unavailable` because this is the one part of the
    harness that needs a Mac, a network and a key. A run that has already paid for a
    search should report what it found rather than exit on a missing `say`.
    """
    if not args.verify_live:
        return None

    import os  # noqa: PLC0415 — only this path needs the environment

    import live  # noqa: PLC0415 — subprocess + urllib, unused by every other path

    api_key = os.environ.get("ASSEMBLYAI_API_KEY")
    if not api_key:
        print("\nSkipping --verify-live: ASSEMBLYAI_API_KEY is not set.")
        return None

    sample = test[: args.verify_live]
    runs = [(winner_name, winner_instruction)]
    if args.verify_baseline:
        # `None` sends an empty llm block — the service's own default wording, which is
        # what Blurt ships today and what no text-only candidate can stand in for.
        runs.append(("service default (empty llm)", None))

    summaries: dict[str, dict[str, float]] = {}
    try:
        with Progress(len(runs) * len(sample), "Verifying against the real endpoint") as meter:
            for name, instruction in runs:
                results = live.verify(
                    sample, instruction, api_key, on_example=lambda n=name: meter.tick(n)
                )
                summaries[name] = live.summarize(results)
    except live.Unavailable as error:
        print(f"\nSkipping --verify-live: {error}")
        return None

    print(f"\nReal endpoint, {len(sample)} held-out utterances through synthesized audio")
    print(f"  {'instruction':<30} {'no-rewrite':>11} {'delivered':>11} {'gain':>8} {'llm_err':>8}")
    print(f"  {'-' * 30} {'-' * 11} {'-' * 11} {'-' * 8} {'-' * 8}")
    for name, summary in summaries.items():
        print(
            f"  {name:<30} {summary['floor_content']:>11.4f} {summary['content']:>11.4f} "
            f"{summary['gain']:>+8.4f} {summary['llm_error_rate']:>8.0%}"
        )
    print(
        "  Synthesized speech is not dictated speech and the STT pass adds its own errors,\n"
        "  so read the ranking, not the absolute scores. Same audio for every row."
    )
    return summaries


def resolve_axis(requested: str, loaded: corpus.Corpus) -> str:
    """Refuse to select on an axis the corpus cannot measure.

    Some corpora carry casing or punctuation their targets did not intend — most
    often because the clean side was produced by mechanically deleting spans, which
    strands the following word in lowercase. Scoring formatting against that
    penalizes a *correct* cleanup, so `blend` degrades to `content` with a note and
    an explicit `--metric format` is an error rather than a meaningless number.
    """
    if loaded.formatting_is_measurable or requested == "content":
        return requested
    if requested == "format":
        raise SystemExit(
            f"--metric format needs a corpus with trustworthy target formatting; "
            f"{loaded.source} does not have it. Use --source nyra for repaired casing, or "
            "--source fleurs --strip-formatting to pose formatting restoration as a task."
        )
    print(
        f"\nNote: {loaded.source} targets carry formatting artifacts from mechanical "
        "cleanup, so the formatting axis would penalize a correct answer — selecting on content."
    )
    return "content"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    check_candidates()

    loaded = corpus.load(
        source=args.source,
        loader=args.loader,
        limit=args.limit,
        split=args.split,
        jsonl=args.jsonl,
        seed=args.seed,
        severity=args.severity,
        strip_formatting=args.strip_formatting,
    )
    print(f"Loaded {len(loaded)} pairs from {loaded.source}: {loaded.detail}")
    print(f"{loaded.disfluent_fraction:.0%} of pairs differ from their target")

    train, dev, test = corpus.split(
        list(loaded.utterances), args.seed, args.dev_fraction, args.test_fraction
    )
    # The optimizer's valset comes off train, not out of dev. Three sets, three jobs:
    # the search tracks candidates against `validation`, dev decides which instruction
    # ships, and test is the number reported. Carving the valset from dev instead —
    # which is what this did until the sets were separated — leaves the set that
    # steered the search also judging it, and a search that overfits 50 rows then
    # reports its overfitting as a win.
    n_validation = corpus.slice_size(args.gepa_valset, len(train))
    validation, train = train[:n_validation], train[n_validation:]
    print(
        f"Split: {len(train)} train / {len(validation)} optimizer valset / "
        f"{len(dev)} dev / {len(test)} test"
    )

    if args.show_samples:
        print_samples(loaded, args.show_samples)

    axis = resolve_axis(args.metric, loaded)
    floors = {"dev": corpus.no_cleanup_floor(dev), "test": corpus.no_cleanup_floor(test)}
    print(
        f"\nNo-cleanup floor ({axis}) — the corpus's disfluent side scored against its "
        f"own target, no model involved: dev {floors['dev'][axis]:.4f}, "
        f"test {floors['test'][axis]:.4f}"
    )

    if args.dry_run:
        print("\n--dry-run: corpus and scoring verified; no model was called.")
        return 0

    import program  # noqa: PLC0415 — deferred so the dry-run path never imports DSPy

    spec = program.ModelSpec(
        model=args.model,
        api_base=args.api_base,
        max_tokens=args.max_tokens,
        reflection_max_tokens=args.reflection_max_tokens,
        temperature=args.temperature,
    )
    program.configure(spec, adapter=args.adapter)

    scoring = resolve_candidates(args)
    dev_rows: list[tuple[str, dict[str, float]]] = []
    with Progress(len(scoring) * len(dev), "Scoring candidates on dev") as meter:
        for index, name in enumerate(scoring, start=1):
            note = f"{name} ({index}/{len(scoring)})"
            scores = program.evaluate(
                program.build(CANDIDATES[name]),
                dev,
                args.num_threads,
                on_example=lambda n=note: meter.tick(n),
            )
            dev_rows.append((name, scores))
    print_table(dev_rows, f"Candidate instructions on dev, selecting on {axis}", axis)

    winner_name, winner_scores = max(dev_rows, key=lambda row: row[1][axis])
    winner_instruction = CANDIDATES[winner_name]

    if args.optimizer != "none":
        # The seed is an ordinary candidate — it fits the cap, so it was scored in the
        # sweep above and may legitimately win. Nothing to score separately, and no
        # need to keep it out of the selection: unlike the over-cap instruction this
        # replaced, shipping it is a real option.
        seed_name = BASELINE if args.start == "prior-winner" else winner_name
        seed_instruction = CANDIDATES[seed_name]
        seed_scores = dict(dev_rows)[seed_name]

        # Only GEPA can be held to the cap during the search; MIPROv2 exposes no
        # proposal hook, so say so rather than letting a run look constrained when the
        # only thing standing between it and an unsendable winner is the final gate.
        proposer = (
            program.CappedInstructionProposer(INSTRUCTION_CHARACTER_CAP)
            if args.optimizer == "gepa"
            else None
        )
        if proposer is None:
            print(
                f"\nNote: {args.optimizer} has no proposal hook, so its search is not held to "
                f"the {INSTRUCTION_CHARACTER_CAP}-character cap — only the final selection is."
            )

        print(f"\nRunning {args.optimizer} from {seed_name} ({describe_length(seed_instruction)})…")
        optimized = program.optimize(
            program.build(seed_instruction),
            optimizer=args.optimizer,
            axis=axis,
            spec=spec,
            reflection_model=args.reflection_model,
            train=train,
            validation=validation,
            auto=args.auto,
            num_threads=args.num_threads,
            instruction_budget=INSTRUCTION_CHARACTER_CAP,
            proposer=proposer,
            reflection_minibatch_size=args.reflection_minibatch_size,
        )
        optimized_instruction = optimized.signature.instructions
        if proposer is not None and proposer.rejected:
            # A search that spent itself fighting the cap should be visible, not
            # inferred from a disappointing score.
            print(
                f"\nThe proposer rejected {proposer.rejected} over-cap proposal(s); "
                f"{proposer.abandoned} component update(s) were abandoned and left unchanged "
                "after the retries."
            )
        with Progress(len(dev), "Re-scoring the optimized instruction") as meter:
            optimized_scores = program.evaluate(
                optimized, dev, args.num_threads, on_example=meter.tick
            )
        dev_rows.append((f"{args.optimizer}-optimized", optimized_scores))
        print_table(dev_rows, f"With the optimized instruction, on dev ({axis})", axis)
        print(f"\nThe optimized instruction is {describe_length(optimized_instruction)}.")
        delta = optimized_scores[axis] - seed_scores[axis]
        print(
            f"Against {seed_name}, the instruction it started from: {delta:+.4f} on {axis} "
            f"({seed_scores[axis]:.4f} → {optimized_scores[axis]:.4f})."
        )

        # The shippability gate comes before the score comparison, because a better
        # score on an instruction that cannot ship is not a better instruction. The
        # same `objections` the proposer re-asks on, applied once more at the end:
        # under GEPA they should already be satisfied, but the proposer gives up after
        # its retries and MIPROv2 has no proposal hook at all, so this is the guarantee.
        final_objections = objections(
            optimized_instruction, (program.INPUT_FIELD, program.OUTPUT_FIELD)
        )
        if final_objections:
            listed = "\n".join(f"  - {note}" for note in final_objections)
            print(
                f"\nRefusing to select it. Keeping {winner_name}.\n{listed}\n"
                "The search is stochastic, so re-running is worth a try; --auto heavy buys "
                "more of it, and --start best-candidate begins from a short instruction "
                "instead of asking the reflector to cut a long one down."
            )
        elif optimized_scores[axis] > winner_scores[axis]:
            winner_name = f"{args.optimizer}-optimized"
            winner_instruction = optimized_instruction
        else:
            print(
                f"\n{args.optimizer} did not beat {winner_name} on dev; keeping the hand-written one."
            )

    # Held-out test scores for the winner and for the shipped-default proxy, so the
    # reported improvement is measured on data no selection decision saw.
    scored_on_test = [(winner_name, winner_instruction)]
    if winner_name != BASELINE:
        scored_on_test.append((BASELINE, CANDIDATES[BASELINE]))
    test_rows = []
    with Progress(len(scored_on_test) * len(test), "Scoring on held-out test") as meter:
        for name, instruction in scored_on_test:
            test_rows.append(
                (
                    name,
                    program.evaluate(
                        program.build(instruction),
                        test,
                        args.num_threads,
                        on_example=lambda n=name: meter.tick(n),
                    ),
                )
            )
    print_table(test_rows, f"Held-out test ({axis})", axis)

    live_summary = run_live_verification(args, winner_name, winner_instruction, test)

    print(f"\nBest cleanup instruction ({describe_length(winner_instruction)}):\n")
    print(f"  {winner_instruction}\n")
    print(
        "Send it as the dictation request's `config.llm.instruction` — see\n"
        "  Sources/BlurtEngine/STT/AssemblyAITranscriber.swift (the `LLMRewrite` struct),\n"
        "which today encodes an empty `llm` object and so selects the service default.\n"
        "Store it verbatim: this harness scores instructions in the same envelope the\n"
        "service applies them in, so a hand-tidied copy is an unscored string."
    )

    if args.out:
        results = {
            "config": vars(args),
            "selected_axis": axis,
            "instruction_character_cap": INSTRUCTION_CHARACTER_CAP,
            "corpus": {
                "source": loaded.source,
                "detail": loaded.detail,
                "count": len(loaded),
                "disfluent_fraction": loaded.disfluent_fraction,
                "formatting_is_measurable": loaded.formatting_is_measurable,
            },
            "split": {"train": len(train), "dev": len(dev), "test": len(test)},
            "no_cleanup_floor": floors,
            "dev": dict(dev_rows),
            "test": dict(test_rows),
            "winner": {
                "name": winner_name,
                "instruction": winner_instruction,
                "length": len(winner_instruction),
            },
            "live": live_summary,
            "candidates": CANDIDATES,
        }
        Path(args.out).write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        print(f"\nWrote {args.out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
