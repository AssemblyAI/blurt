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
Reference transcripts come from a Hugging Face speech dataset — real sentences
spoken into a microphone, hand-transcribed with true casing and punctuation.
Disfluencies are then injected into them (`disfluency.py`), producing the messy
verbatim text a speech-to-text model returns for spontaneous dictation. A cleanup
prompt is scored on how closely its output restores the original reference
(`metrics.py`). Injection is additive, so the reference is exactly recoverable and
a perfect prompt would score 1.0.

Because the injection is synthetic, the ranking transfers further than the
absolute numbers do — treat a winning score as "this instruction beats that one on
this disfluency distribution", not as a prediction of production quality.

Usage
-----
    export ANTHROPIC_API_KEY=...
    uv run evals/dictation-prompt/optimize_cleanup_prompt.py --limit 150

    # No network and no API key — checks the pipeline end to end.
    python evals/dictation-prompt/optimize_cleanup_prompt.py --source builtin --dry-run

    # Evolve a new instruction instead of only ranking the hand-written ones.
    uv run evals/dictation-prompt/optimize_cleanup_prompt.py --optimizer gepa

`--dry-run` and the tests need no third-party packages; DSPy is imported lazily so
the data and scoring paths stay runnable on a bare interpreter.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import corpus  # noqa: E402
import metrics  # noqa: E402
from disfluency import Utterance, inject_all  # noqa: E402

# Candidate cleanup instructions, each a different hypothesis about what the
# rewrite model needs to be told. `default-proxy` stands in for the service's own
# default instruction (the empty `llm` block Blurt sends today) so every run has a
# "did we beat what we already ship" comparison. The rest vary one thing each:
# how the task is framed, how explicitly the disfluency types are named, how hard
# the do-not-rewrite constraint is pushed, and whether formatting is called out.
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

# Field descriptions ride along with the instruction into the program's prompt.
# They stay fixed across candidates so the only thing varying between arms is the
# instruction itself — the string that would actually be shipped.
FIELD_DESCRIPTIONS = {
    "raw_transcript": "Verbatim speech-to-text output for one dictated utterance.",
    "cleaned_transcript": "The same utterance as finished written text.",
}


@dataclass
class Split:
    """Train / dev / test partition of the injected examples."""

    train: list[Utterance]
    dev: list[Utterance]
    test: list[Utterance]


def split_examples(utterances: list[Utterance], seed: int, dev_fraction: float, test_fraction: float) -> Split:
    """Shuffle once with a fixed seed, then slice.

    Shuffling matters because HF splits are often ordered by speaker or source
    document; slicing an unshuffled corpus would put systematically different
    material in train and test.
    """
    shuffled = list(utterances)
    random.Random(seed).shuffle(shuffled)
    total = len(shuffled)
    n_test = max(1, int(total * test_fraction)) if total > 2 else 0
    n_dev = max(1, int(total * dev_fraction)) if total > 2 else 0
    test = shuffled[:n_test]
    dev = shuffled[n_test : n_test + n_dev]
    train = shuffled[n_test + n_dev :]
    return Split(train=train, dev=dev, test=test)


# --------------------------------------------------------------------------
# Scoring helpers that need no DSPy
# --------------------------------------------------------------------------


def mean_score(pairs: list[tuple[str, str]], metric: str) -> float:
    """Average score over (reference, hypothesis) pairs; 0.0 for an empty set."""
    if not pairs:
        return 0.0
    return sum(metrics.score(ref, hyp).value(metric) for ref, hyp in pairs) / len(pairs)


def echo_floor(utterances: list[Utterance], metric: str) -> float:
    """Score of doing nothing at all — pasting the verbatim transcript unchanged.

    This is the number any candidate instruction has to beat to be worth sending;
    a prompt that scores below it is actively making the transcript worse.
    """
    return mean_score([(u.reference, u.disfluent) for u in utterances], metric)


# --------------------------------------------------------------------------
# DSPy program
# --------------------------------------------------------------------------


def build_program(instruction: str):
    """A single-step `Predict` whose instruction is the thing being optimized.

    Deliberately not `ChainOfThought`: the winning instruction has to be portable
    into `config.llm.instruction`, a lone string the service applies in one pass.
    A program whose quality depended on an extra reasoning field would not survive
    that trip.
    """
    import dspy

    signature = (
        dspy.Signature("raw_transcript -> cleaned_transcript")
        .with_instructions(instruction)
        .with_updated_fields("raw_transcript", desc=FIELD_DESCRIPTIONS["raw_transcript"])
        .with_updated_fields("cleaned_transcript", desc=FIELD_DESCRIPTIONS["cleaned_transcript"])
    )
    return dspy.Predict(signature)


def instruction_of(program) -> str:
    """Read the (possibly optimized) instruction back out of a program."""
    return program.signature.instructions


def to_examples(utterances: list[Utterance]):
    """Wrap utterances as DSPy examples keyed on the field names the program uses."""
    import dspy

    return [
        dspy.Example(
            raw_transcript=u.disfluent,
            cleaned_transcript=u.reference,
        ).with_inputs("raw_transcript")
        for u in utterances
    ]


def make_metric(metric: str):
    """Scalar metric for `Evaluate` and MIPROv2."""

    def scorer(gold, pred, trace=None, **_):
        hypothesis = getattr(pred, "cleaned_transcript", "") or ""
        return metrics.score(gold.cleaned_transcript, hypothesis).value(metric)

    return scorer


def make_feedback_metric(metric: str):
    """Metric for GEPA: the same score plus a diff its reflector can act on."""
    import dspy

    def scorer(gold, pred, trace=None, pred_name=None, pred_trace=None, **_):
        hypothesis = getattr(pred, "cleaned_transcript", "") or ""
        scored = metrics.score(gold.cleaned_transcript, hypothesis)
        return dspy.Prediction(
            score=scored.value(metric),
            feedback=metrics.feedback(gold.cleaned_transcript, hypothesis, scored),
        )

    return scorer


def evaluate(program, utterances: list[Utterance], metric: str, num_threads: int) -> dict[str, float]:
    """Run a program over a split and report all three axes.

    Reports content and format alongside the selected metric so a winner chosen on
    `blend` can still be inspected for *why* it won — a prompt that gains on
    punctuation while losing words is a bad trade the blended number would hide.
    """
    import dspy

    examples = to_examples(utterances)
    # The caller prints one line per candidate; a nested per-example bar on top of
    # that renders as interleaved carriage-return noise in a piped log.
    runner = dspy.Parallel(
        num_threads=num_threads,
        provide_traceback=True,
        disable_progress_bar=True,
    )
    predictions = runner([(program, dict(example.inputs())) for example in examples])
    pairs = [
        (utterance.reference, getattr(prediction, "cleaned_transcript", "") or "")
        for utterance, prediction in zip(utterances, predictions, strict=True)
    ]
    return {
        "content": mean_score(pairs, "content"),
        "format": mean_score(pairs, "format"),
        "blend": mean_score(pairs, "blend"),
        "selected": mean_score(pairs, metric),
    }


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def print_table(rows: list[tuple[str, dict[str, float]]], title: str) -> None:
    print(f"\n{title}")
    print(f"  {'candidate':<22} {'selected':>9} {'content':>9} {'format':>9}")
    print(f"  {'-' * 22} {'-' * 9} {'-' * 9} {'-' * 9}")
    for name, scores in rows:
        print(
            f"  {name:<22} {scores['selected']:>9.4f} "
            f"{scores['content']:>9.4f} {scores['format']:>9.4f}"
        )


def print_samples(utterances: list[Utterance], count: int) -> None:
    print(f"\nInjected examples (showing {min(count, len(utterances))} of {len(utterances)})")
    for utterance in utterances[:count]:
        floor = metrics.score(utterance.reference, utterance.disfluent)
        print(f"\n  reference : {utterance.reference}")
        print(f"  disfluent : {utterance.disfluent}")
        print(f"  operations: {', '.join(utterance.operations) or '(none)'}")
        print(f"  echo score: content {floor.content:.3f} / format {floor.format:.3f}")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    data = parser.add_argument_group("data")
    data.add_argument(
        "--source",
        default="datasets-server",
        choices=("datasets-server", "datasets", "builtin"),
        help="where reference transcripts come from (default: the HF rows API)",
    )
    data.add_argument("--dataset", default=corpus.DEFAULT_DATASET)
    data.add_argument("--config", default=corpus.DEFAULT_CONFIG)
    data.add_argument("--split", default=corpus.DEFAULT_SPLIT)
    data.add_argument(
        "--text-field",
        default=corpus.DEFAULT_TEXT_FIELD,
        help="dataset column holding the punctuated reference transcript",
    )
    data.add_argument("--limit", type=int, default=120, help="how many references to load")
    data.add_argument("--jsonl", help="load references from a local .jsonl instead of a dataset")

    injection = parser.add_argument_group("disfluency injection")
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
        choices=("blend", "content", "format"),
        help="which score selects the winner (default: blend, 0.7 content / 0.3 format)",
    )
    evaluation.add_argument("--dev-fraction", type=float, default=0.3)
    evaluation.add_argument("--test-fraction", type=float, default=0.3)
    evaluation.add_argument("--num-threads", type=int, default=8)
    evaluation.add_argument(
        "--dry-run",
        action="store_true",
        help="build and score the dataset without calling any model",
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
    model.add_argument(
        "--api-base",
        default=None,
        help="override the API base URL (e.g. an OpenAI-compatible gateway)",
    )
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


def configure_lm(args) -> None:
    """Point DSPy at the model standing in for the service-side rewrite."""
    import dspy

    kwargs: dict[str, object] = {"max_tokens": args.max_tokens}
    if args.api_base:
        kwargs["api_base"] = args.api_base
    # Sampling parameters are deliberately not set: current Claude models reject
    # `temperature`, and DSPy omits it when left unset.
    dspy.configure(lm=dspy.LM(args.model, **kwargs))


def run_optimizer(args, program, split: Split, metric: str):
    """Evolve the instruction, returning the optimized program."""
    import dspy

    train = to_examples(split.train)
    dev = to_examples(split.dev)

    if args.optimizer == "gepa":
        reflection = dspy.LM(
            args.reflection_model or args.model,
            max_tokens=8192,
            **({"api_base": args.api_base} if args.api_base else {}),
        )
        optimizer = dspy.GEPA(
            metric=make_feedback_metric(metric),
            auto=args.auto,
            reflection_lm=reflection,
            num_threads=args.num_threads,
        )
        return optimizer.compile(program, trainset=train, valset=dev)

    # MIPROv2 with both demo budgets at zero: it then searches instructions only,
    # which is what `config.llm.instruction` can actually carry. Few-shot demos
    # would improve the DSPy program and be unshippable.
    optimizer = dspy.MIPROv2(
        metric=make_metric(metric),
        auto=args.auto,
        max_bootstrapped_demos=0,
        max_labeled_demos=0,
        num_threads=args.num_threads,
    )
    return optimizer.compile(
        program,
        trainset=train,
        valset=dev,
        requires_permission_to_run=False,
    )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    loaded = corpus.load(
        source=args.source,
        dataset=args.dataset,
        config=args.config,
        split=args.split,
        text_field=args.text_field,
        limit=args.limit,
        jsonl=args.jsonl,
    )
    print(f"Loaded {len(loaded)} reference transcripts from {loaded.source}: {loaded.detail}")

    utterances = inject_all(
        list(loaded.references),
        seed=args.seed,
        severity=args.severity,
        strip_formatting=args.strip_formatting,
    )
    split = split_examples(utterances, args.seed, args.dev_fraction, args.test_fraction)
    print(f"Split: {len(split.train)} train / {len(split.dev)} dev / {len(split.test)} test")

    if args.show_samples:
        print_samples(utterances, args.show_samples)

    floors = {
        "dev": echo_floor(split.dev, args.metric),
        "test": echo_floor(split.test, args.metric),
    }
    print(
        f"\nEcho floor ({args.metric}) — pasting the transcript uncleaned: "
        f"dev {floors['dev']:.4f}, test {floors['test']:.4f}"
    )

    if args.dry_run:
        print("\n--dry-run: dataset and scoring verified; no model was called.")
        return 0

    configure_lm(args)

    dev_rows: list[tuple[str, dict[str, float]]] = []
    for name, instruction in CANDIDATES.items():
        scores = evaluate(build_program(instruction), split.dev, args.metric, args.num_threads)
        dev_rows.append((name, scores))
        print(f"  scored {name:<22} dev {args.metric} {scores['selected']:.4f}")
    dev_rows.sort(key=lambda row: row[1]["selected"], reverse=True)
    print_table(dev_rows, f"Candidate instructions on dev ({args.metric})")

    best_name, _ = dev_rows[0]
    winner_name = best_name
    winner_instruction = CANDIDATES[best_name]

    if args.optimizer != "none":
        print(f"\nRunning {args.optimizer} from the best hand-written candidate ({best_name})…")
        optimized = run_optimizer(args, build_program(winner_instruction), split, args.metric)
        optimized_instruction = instruction_of(optimized)
        optimized_dev = evaluate(optimized, split.dev, args.metric, args.num_threads)
        dev_rows.append((f"{args.optimizer}-optimized", optimized_dev))
        print_table(
            sorted(dev_rows, key=lambda row: row[1]["selected"], reverse=True),
            f"With the optimized instruction, on dev ({args.metric})",
        )
        if optimized_dev["selected"] > dict(dev_rows)[best_name]["selected"]:
            winner_name = f"{args.optimizer}-optimized"
            winner_instruction = optimized_instruction
        else:
            print(
                f"\n{args.optimizer} did not beat {best_name} on dev; "
                "keeping the hand-written instruction."
            )

    # Held-out test scores for the winner and for the shipped-default proxy, so
    # the reported improvement is measured on data no selection decision saw.
    test_rows = [
        (winner_name, evaluate(build_program(winner_instruction), split.test, args.metric, args.num_threads)),
    ]
    if winner_name != "default-proxy":
        test_rows.append(
            ("default-proxy", evaluate(build_program(CANDIDATES["default-proxy"]), split.test, args.metric, args.num_threads))
        )
    print_table(test_rows, f"Held-out test ({args.metric})")

    print("\nBest cleanup instruction:\n")
    print(f"  {winner_instruction}\n")
    print(
        "Send it as the dictation request's `config.llm.instruction` — see\n"
        "  Sources/BlurtEngine/STT/AssemblyAITranscriber.swift (the `LLMRewrite` struct),\n"
        "which today encodes an empty `llm` object and so selects the service default."
    )

    results = {
        "config": vars(args),
        "corpus": {"source": loaded.source, "detail": loaded.detail, "count": len(loaded)},
        "split": {"train": len(split.train), "dev": len(split.dev), "test": len(split.test)},
        "echo_floor": floors,
        "dev": {name: scores for name, scores in dev_rows},
        "test": {name: scores for name, scores in test_rows},
        "winner": {"name": winner_name, "instruction": winner_instruction},
        "candidates": CANDIDATES,
    }
    if args.out:
        Path(args.out).write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        print(f"\nWrote {args.out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
