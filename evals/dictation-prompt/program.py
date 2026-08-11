"""Everything that touches DSPy.

Isolated in one module on purpose. The harness promises that `--dry-run` and the
test suite run on a bare interpreter — building the corpus, injecting
disfluencies, and scoring need only the standard library. Keeping every DSPy
import behind this module's own import makes that property structural rather than
a convention repeated at six call sites: the CLI imports this module only after
the dry-run early return, and a test can assert `dspy` never reached `sys.modules`.
"""

from __future__ import annotations

from dataclasses import dataclass

import dspy

import metrics
from corpus import Utterance


def build(instruction: str) -> dspy.Predict:
    """A single-step `Predict` whose instruction is the thing being optimized.

    Deliberately not `ChainOfThought`: the winning instruction has to be portable
    into `config.llm.instruction`, a lone string the service applies in one pass.
    A program whose quality depended on an extra reasoning field would not survive
    that trip.
    """
    signature = (
        dspy.Signature("raw_transcript -> cleaned_transcript")
        .with_instructions(instruction)
        .with_updated_fields(
            "raw_transcript", desc="Verbatim speech-to-text output for one dictated utterance."
        )
        .with_updated_fields(
            "cleaned_transcript", desc="The same utterance as finished written text."
        )
    )
    return dspy.Predict(signature)


def to_examples(utterances: list[Utterance]) -> list[dspy.Example]:
    """Wrap utterances as DSPy examples for the optimizers' train/val sets."""
    return [
        dspy.Example(
            raw_transcript=u.disfluent,
            cleaned_transcript=u.reference,
        ).with_inputs("raw_transcript")
        for u in utterances
    ]


def _cleaned(prediction) -> str:
    """The model's output, tolerating the `None` a failed parallel item yields."""
    return getattr(prediction, "cleaned_transcript", "") or ""


def make_metric(axis: str):
    """Scalar metric for MIPROv2, which searches on a single number."""

    def scorer(gold, pred, trace=None, **_):
        return metrics.score(gold.cleaned_transcript, _cleaned(pred)).value(axis)

    return scorer


def make_feedback_metric(axis: str):
    """Metric for GEPA: the same score plus a diff its reflector can act on."""

    def scorer(gold, pred, trace=None, pred_name=None, pred_trace=None, **_):
        hypothesis = _cleaned(pred)
        scored = metrics.score(gold.cleaned_transcript, hypothesis)
        return dspy.Prediction(
            score=scored.value(axis),
            feedback=metrics.feedback(
                gold.cleaned_transcript, hypothesis, gold.raw_transcript, scored
            ),
        )

    return scorer


def evaluate(program, utterances: list[Utterance], num_threads: int) -> dict[str, float]:
    """Run a program over a split and report every axis.

    Each pair is scored exactly once and all axes are read off that one result —
    `metrics.score` computes both alignments regardless, so averaging the axes
    separately would repeat the work per axis for nothing.
    """
    # The caller prints one line per candidate; a nested per-example bar on top of
    # that renders as interleaved carriage-return noise in a piped log.
    runner = dspy.Parallel(num_threads=num_threads, provide_traceback=True, disable_progress_bar=True)
    predictions = runner([(program, {"raw_transcript": u.disfluent}) for u in utterances])
    return metrics.mean(
        [
            metrics.score(utterance.reference, _cleaned(prediction))
            for utterance, prediction in zip(utterances, predictions, strict=True)
        ]
    )


@dataclass(frozen=True)
class ModelSpec:
    """How to reach the model standing in for the service's rewrite."""

    model: str
    api_base: str | None = None
    max_tokens: int = 2048

    def lm(self, *, model: str | None = None, max_tokens: int | None = None) -> dspy.LM:
        """Build an LM, overriding the model or budget for a secondary role.

        Sampling parameters are deliberately never set: current Claude models
        reject `temperature`, and DSPy omits it when left unset.
        """
        kwargs: dict[str, object] = {"max_tokens": max_tokens or self.max_tokens}
        if self.api_base:
            kwargs["api_base"] = self.api_base
        return dspy.LM(model or self.model, **kwargs)


def configure(spec: ModelSpec) -> None:
    """Point DSPy at the model standing in for the service-side rewrite."""
    dspy.configure(lm=spec.lm())


def optimize(
    program,
    *,
    optimizer: str,
    axis: str,
    spec: ModelSpec,
    reflection_model: str | None,
    train: list[Utterance],
    dev: list[Utterance],
    auto: str,
    num_threads: int,
):
    """Evolve the instruction, returning the optimized program."""
    trainset, valset = to_examples(train), to_examples(dev)

    if optimizer == "gepa":
        return dspy.GEPA(
            metric=make_feedback_metric(axis),
            auto=auto,
            reflection_lm=spec.lm(model=reflection_model, max_tokens=8192),
            num_threads=num_threads,
        ).compile(program, trainset=trainset, valset=valset)

    # MIPROv2 with both demo budgets at zero: it then searches instructions only,
    # which is what `config.llm.instruction` can actually carry. Few-shot demos
    # would improve the DSPy program and be unshippable.
    return dspy.MIPROv2(
        metric=make_metric(axis),
        auto=auto,
        max_bootstrapped_demos=0,
        max_labeled_demos=0,
        num_threads=num_threads,
    ).compile(program, trainset=trainset, valset=valset, requires_permission_to_run=False)
