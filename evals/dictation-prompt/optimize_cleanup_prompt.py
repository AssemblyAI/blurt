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
        default=50,
        metavar="ROWS_OR_FRACTION",
        help="dev rows, absolute at 1 or above and a fraction below (default: 50). Dev is "
        "GEPA's valset AND the set that ranks every candidate, so each row is paid for "
        "roughly eight times over plus GEPA's full evals — it is the most expensive slice "
        "and buys no extra exploration, which depends only on --auto",
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
        default="medium",
        choices=("light", "medium", "heavy"),
        help="optimizer search budget (default: medium). This is the knob that decides how "
        "many ideas get tried — 10 reflection trials at light, 18 at medium, 27 at heavy, "
        "independent of corpus size. Shrinking --dev-fraction makes each trial cheaper; "
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

    parser.add_argument("--out", default=None, help="write the full results as JSON to this path")
    return parser.parse_args(argv)


def describe_length(instruction: str) -> str:
    """`2048 chars` plus how that sits against the cap — the line every report ends on."""
    over = overage(instruction)
    if over:
        return f"{len(instruction)} chars — {over} OVER the {INSTRUCTION_CHARACTER_CAP} cap"
    headroom = INSTRUCTION_CHARACTER_CAP - len(instruction)
    return f"{len(instruction)} chars, {headroom} under the {INSTRUCTION_CHARACTER_CAP} cap"


def check_candidate_lengths() -> None:
    """Refuse to start if a hand-written candidate could never be sent.

    Before any model call, because this is a typo-class mistake and paying for a full
    sweep to discover it is pure waste. Nothing is exempt, `prior-winner` included:
    it earned its place in the table by being compressed under the cap, and if a later
    edit pushes it back over, this is what says so.
    """
    offenders = [(name, text) for name, text in CANDIDATES.items() if overage(text)]
    if not offenders:
        return
    detail = "\n".join(f"  {name}: {describe_length(text)}" for name, text in offenders)
    raise SystemExit(
        "These candidates.py instructions exceed the dictation API's "
        f"{INSTRUCTION_CHARACTER_CAP}-character cap on config.llm.instruction, so the "
        f"request would 400 before the audio is read:\n{detail}"
    )


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
    check_candidate_lengths()

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
    print(f"Split: {len(train)} train / {len(dev)} dev / {len(test)} test")

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

    spec = program.ModelSpec(model=args.model, api_base=args.api_base, max_tokens=args.max_tokens)
    program.configure(spec, adapter=args.adapter)

    dev_rows: list[tuple[str, dict[str, float]]] = []
    with Progress(len(CANDIDATES) * len(dev), "Scoring candidates on dev") as meter:
        for index, (name, instruction) in enumerate(CANDIDATES.items(), start=1):
            note = f"{name} ({index}/{len(CANDIDATES)})"
            scores = program.evaluate(
                program.build(instruction),
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
            dev=dev,
            auto=args.auto,
            num_threads=args.num_threads,
            instruction_budget=INSTRUCTION_CHARACTER_CAP,
            proposer=proposer,
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

        # The length gate comes before the score comparison, because a better score on
        # an unsendable instruction is not a better instruction. Enforced here rather
        # than inside the optimizer: the budget reaches GEPA only as feedback prose it
        # is free to ignore, and reaches MIPROv2 not at all.
        if overage(optimized_instruction):
            print(
                f"\nRefusing to select it: over the {INSTRUCTION_CHARACTER_CAP}-character cap on "
                "config.llm.instruction, so every request carrying it would 400. Keeping "
                f"{winner_name}. The search is stochastic, so re-running is worth a try; "
                "--auto medium buys more of it, and --start best-candidate begins from a short "
                "instruction instead of asking the reflector to cut a long one down. Do not "
                "raise INSTRUCTION_CHARACTER_CAP — it is the API's limit, not a preference."
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
            "candidates": CANDIDATES,
        }
        Path(args.out).write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        print(f"\nWrote {args.out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
