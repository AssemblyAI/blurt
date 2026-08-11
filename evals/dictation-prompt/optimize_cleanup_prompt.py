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
    export ANTHROPIC_API_KEY=...
    uv run evals/dictation-prompt/optimize_cleanup_prompt.py --limit 150

    # No network and no API key — checks the pipeline end to end.
    python3 evals/dictation-prompt/optimize_cleanup_prompt.py --source builtin --dry-run

    # Evolve a new instruction instead of only ranking the hand-written ones.
    uv run evals/dictation-prompt/optimize_cleanup_prompt.py --optimizer gepa

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
from candidates import BASELINE, CANDIDATES  # noqa: E402
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
    data.add_argument("--limit", type=int, default=120, help="how many pairs to load")
    data.add_argument(
        "--split",
        default=None,
        help="override the dataset split; each source defaults to its (small) held-out "
        "split, so large runs want --split train",
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
    evaluation.add_argument("--dev-fraction", type=float, default=0.3)
    evaluation.add_argument("--test-fraction", type=float, default=0.3)
    evaluation.add_argument("--num-threads", type=int, default=8)
    evaluation.add_argument(
        "--dry-run",
        action="store_true",
        help="build and score the corpus without calling any model",
    )
    evaluation.add_argument("--show-samples", type=int, default=3)

    model = parser.add_argument_group("model")
    model.add_argument(
        "--model",
        default="anthropic/claude-opus-5",
        help="LiteLLM model id standing in for the service's rewrite model",
    )
    model.add_argument(
        "--reflection-model",
        default=None,
        help="model that rewrites instructions during --optimizer gepa (default: --model)",
    )
    model.add_argument("--api-base", default=None, help="override the API base URL")
    model.add_argument("--max-tokens", type=int, default=2048)

    search = parser.add_argument_group("search")
    search.add_argument(
        "--optimizer",
        default="none",
        choices=("none", "gepa", "mipro"),
        help="none ranks the built-in candidates; gepa/mipro also evolve a new instruction",
    )
    search.add_argument(
        "--auto",
        default="light",
        choices=("light", "medium", "heavy"),
        help="optimizer search budget",
    )

    parser.add_argument("--out", default=None, help="write the full results as JSON to this path")
    return parser.parse_args(argv)


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
    program.configure(spec)

    dev_rows: list[tuple[str, dict[str, float]]] = []
    with Progress(len(CANDIDATES) * len(dev), "Scoring candidates on dev") as meter:
        for index, (name, instruction) in enumerate(CANDIDATES.items(), start=1):
            note = f"{name} ({index}/{len(CANDIDATES)})"
            scores = program.evaluate(
                program.build(instruction), dev, args.num_threads, on_example=lambda n=note: meter.tick(n)
            )
            dev_rows.append((name, scores))
    print_table(dev_rows, f"Candidate instructions on dev, selecting on {axis}", axis)

    winner_name, winner_scores = max(dev_rows, key=lambda row: row[1][axis])
    winner_instruction = CANDIDATES[winner_name]

    if args.optimizer != "none":
        print(f"\nRunning {args.optimizer} from the best hand-written candidate ({winner_name})…")
        optimized = program.optimize(
            program.build(winner_instruction),
            optimizer=args.optimizer,
            axis=axis,
            spec=spec,
            reflection_model=args.reflection_model,
            train=train,
            dev=dev,
            auto=args.auto,
            num_threads=args.num_threads,
        )
        with Progress(len(dev), "Re-scoring the optimized instruction") as meter:
            optimized_scores = program.evaluate(
                optimized, dev, args.num_threads, on_example=meter.tick
            )
        dev_rows.append((f"{args.optimizer}-optimized", optimized_scores))
        print_table(dev_rows, f"With the optimized instruction, on dev ({axis})", axis)
        if optimized_scores[axis] > winner_scores[axis]:
            winner_name = f"{args.optimizer}-optimized"
            winner_instruction = optimized.signature.instructions
        else:
            print(f"\n{args.optimizer} did not beat {winner_name} on dev; keeping the hand-written one.")

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

    print("\nBest cleanup instruction:\n")
    print(f"  {winner_instruction}\n")
    print(
        "Send it as the dictation request's `config.llm.instruction` — see\n"
        "  Sources/BlurtEngine/STT/AssemblyAITranscriber.swift (the `LLMRewrite` struct),\n"
        "which today encodes an empty `llm` object and so selects the service default."
    )

    if args.out:
        results = {
            "config": vars(args),
            "selected_axis": axis,
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
            "winner": {"name": winner_name, "instruction": winner_instruction},
            "candidates": CANDIDATES,
        }
        Path(args.out).write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        print(f"\nWrote {args.out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
