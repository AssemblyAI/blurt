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
from gepa.strategies.instruction_proposal import InstructionProposalSignature

import metrics
from candidates import constraint_preamble, objections, revision_directive, trim_to_fit
from corpus import Utterance

#: The harness's own signature field names. They exist for DSPy's benefit and appear
#: in **neither** envelope the instruction is applied in: `PlainChatAdapter` sends the
#: bare transcript as the user turn, and the service sends the bare transcript too.
#:
#: Named here rather than inline because the proposer has to reject instructions that
#: mention them (see `CappedInstructionProposer`), and a gate spelling the names a
#: second time would silently stop matching the day the signature is renamed.
INPUT_FIELD = "raw_transcript"
OUTPUT_FIELD = "cleaned_transcript"


def build(instruction: str) -> dspy.Predict:
    """A single-step `Predict` whose instruction is the thing being optimized.

    Deliberately not `ChainOfThought`: the winning instruction has to be portable
    into `config.llm.instruction`, a lone string the service applies in one pass.
    A program whose quality depended on an extra reasoning field would not survive
    that trip.

    Carries no field descriptions. `PlainChatAdapter` sends the instruction and nothing
    else, and it is now the only adapter — the descriptions existed for the marker
    protocol that `--adapter chat` used, and went with it.
    """
    signature = dspy.Signature(f"{INPUT_FIELD} -> {OUTPUT_FIELD}").with_instructions(instruction)
    return dspy.Predict(signature)


class PlainChatAdapter(dspy.ChatAdapter):
    """Send the instruction as the system prompt and the transcript as the user turn.

    DSPy's default `ChatAdapter` wraps every call in a field-marker protocol —
    `[[ ## raw_transcript ## ]]` in, `[[ ## cleaned_transcript ## ]]` … `[[ ## completed ## ]]`
    back — and parses the reply out of those markers. Two reasons that is the wrong
    envelope for this harness:

    **Fidelity.** What ships is `config.llm.instruction`: one string the service applies
    to one transcript in one pass, with no scaffolding around it. Scoring an instruction
    through the marker protocol measures the instruction *plus* the protocol, and the
    winner has to travel without it. `ChatAdapter` also rewrites the instruction into
    "In adhering to this structure, your objective is: …", so the string under test isn't
    even the string that would ship.

    **Reach.** Small models can't follow the protocol at all. `qwen3.5-4b-32k-fast` echoes
    the user message back verbatim, so no output field parses; `ChatAdapter` then retries
    through `JSONAdapter`, which sets `response_format`, which the AssemblyAI LLM Gateway
    rejects with a 400 for models that don't advertise it. The visible error was that 400,
    three layers below its cause. Since the service's own rewrite model runs under a ~5s
    budget and is probably much smaller than the default `--model`, the models this
    unblocks are the *representative* ones — see the README on transferability.

    Only the harness's own one-in/one-out string signature is handled this way. GEPA
    prompts its own multi-field signatures through the same globally configured
    adapter (`dspy.Predict` reads `settings.adapter`), so every other shape falls straight
    through to `ChatAdapter` — including its `JSONAdapter` fallback. That fall-through is
    why `_is_plain` exists rather than this class simply returning the instruction.
    """

    @staticmethod
    def _is_plain(signature: type[dspy.Signature]) -> bool:
        """Whether this is a lone string in, a lone string out — the shippable shape."""
        fields = (*signature.input_fields.values(), *signature.output_fields.values())
        return (
            len(signature.input_fields) == 1
            and len(signature.output_fields) == 1
            and all(field.annotation is str for field in fields)
        )

    def format_system_message(self, signature: type[dspy.Signature]) -> str:
        if not self._is_plain(signature):
            return super().format_system_message(signature)
        return signature.instructions

    def format_user_message_content(
        self,
        signature: type[dspy.Signature],
        inputs: dict,
        prefix: str = "",
        suffix: str = "",
        main_request: bool = False,
    ) -> str:
        if not self._is_plain(signature):
            return super().format_user_message_content(
                signature, inputs, prefix, suffix, main_request
            )
        (field,) = signature.input_fields
        return f"{prefix}{inputs[field]}{suffix}"

    def format_assistant_message_content(
        self,
        signature: type[dspy.Signature],
        outputs: dict,
        missing_field_message: str | None = None,
    ) -> str:
        if not self._is_plain(signature):
            return super().format_assistant_message_content(
                signature, outputs, missing_field_message
            )
        (field,) = signature.output_fields
        return outputs.get(field) or missing_field_message or ""

    def parse(self, signature: type[dspy.Signature], completion: str) -> dict:
        """The whole completion *is* the answer — which is why this can't fail to parse.

        No markers to find means no `AdapterParseError`, so the eval's own program never
        reaches the `JSONAdapter` fallback that the gateway 400s on.
        """
        if not self._is_plain(signature):
            return super().parse(signature, completion)
        (field,) = signature.output_fields
        return {field: completion.strip()}


def to_examples(utterances: list[Utterance]) -> list[dspy.Example]:
    """Wrap utterances as DSPy examples for the optimizers' train/val sets."""
    return [
        dspy.Example(
            **{INPUT_FIELD: u.disfluent, OUTPUT_FIELD: u.reference},
        ).with_inputs(INPUT_FIELD)
        for u in utterances
    ]


def _cleaned(prediction) -> str:
    """The model's output, tolerating the `None` a failed parallel item yields."""
    return getattr(prediction, OUTPUT_FIELD, "") or ""


def make_feedback_metric(axis: str):
    """Metric for GEPA: the same score plus a diff its reflector can act on.

    `axis` decides which score the reflector is shown, and it is shown only that one.
    Reporting an axis nobody selected on points the search at noise — see
    `metrics.feedback` for why the formatting score in particular is misleading on the
    default corpus. The length budget is not here at all; it belongs in the proposer's
    preamble, said once with the real target rather than eight times with the cap.
    """

    def scorer(gold, pred, trace=None, pred_name=None, pred_trace=None, **_):
        hypothesis = _cleaned(pred)
        scored = metrics.score(getattr(gold, OUTPUT_FIELD), hypothesis)
        return dspy.Prediction(
            score=scored.value(axis),
            feedback=metrics.feedback(
                getattr(gold, OUTPUT_FIELD),
                getattr(gold, INPUT_FIELD),
                scored,
                axis=axis,
            ),
        )

    return scorer


class _Ticking(dspy.Module):
    """Wraps a program so each finished example reports back to a progress meter.

    `dspy.Parallel` has no per-item callback and its own bar can't span more than
    one call, so counting has to happen at the module boundary. The tick fires in
    `finally`: an example that raised still consumed a slot, and a meter that
    stalls on the first failure is worse than no meter.
    """

    def __init__(self, program, on_example):
        super().__init__()
        self.program = program
        self.on_example = on_example

    def forward(self, **kwargs):
        try:
            return self.program(**kwargs)
        finally:
            self.on_example()


def evaluate(
    program, utterances: list[Utterance], num_threads: int, on_example=None
) -> dict[str, float]:
    """Run a program over a split and report every axis.

    Each pair is scored exactly once and all axes are read off that one result —
    `metrics.score` computes both alignments regardless, so averaging the axes
    separately would repeat the work per axis for nothing.
    """
    # DSPy's own bar is disabled: it can only cover a single call, so on a sweep it
    # would restart per candidate, and its carriage returns fight the caller's
    # meter. `on_example` lets the caller show one bar across the whole run.
    runner = dspy.Parallel(
        num_threads=num_threads, provide_traceback=True, disable_progress_bar=True
    )
    counted = program if on_example is None else _Ticking(program, on_example)
    predictions = runner([(counted, {INPUT_FIELD: u.disfluent}) for u in utterances])
    return metrics.mean(
        [
            metrics.score(utterance.reference, _cleaned(prediction))
            for utterance, prediction in zip(utterances, predictions, strict=True)
        ]
    )


class CappedInstructionProposer:
    """GEPA `ProposalFn` that will not hand back an instruction that cannot ship.

    What disqualifies one is `candidates.objections`' to define — none of it visible to
    the score — and this class only decides what to do about it, so that adding a check
    there needs no change here.

    Why this exists rather than a penalty in the metric: GEPA's metric is handed one
    scored *example* and never sees the candidate instruction, so neither property can
    enter the objective there. Stating them in feedback prose (`make_feedback_metric`)
    only asks nicely, and longer instructions tend to score better — so an
    unconstrained search drifts and the run ends with nothing sendable. This is the
    documented hook for constraining what the search may even consider: a bad proposal
    is rejected and re-asked before GEPA ever evaluates it, so no search budget is
    spent scoring a candidate that could not ship.

    Delegates to GEPA's own `InstructionProposalSignature` rather than reimplementing
    the reflection prompt — the quality of that prompt is most of what GEPA is. Only
    the accept/retry decision around it is ours.

    On giving up after `attempts` tries it returns the instruction **unchanged**, not
    a patched-up one. Truncating at the cap lands mid-sentence and deleting a field
    name by hand can leave a dangling clause; a mangled instruction that happens to
    score well is exactly the kind of thing that reaches a build and breaks it. A
    no-op mutation costs GEPA one wasted step and keeps the pool honest.
    """

    def __init__(self, cap: int, attempts: int = 5, fields: tuple[str, ...] = ()):
        self.cap = cap
        self.attempts = attempts
        self.fields = fields or (INPUT_FIELD, OUTPUT_FIELD)
        #: Proposals rejected, over the whole run — reported by the CLI so a search
        #: that spent itself fighting the constraints is visible rather than implied.
        self.rejected = 0
        #: Components the retries never got clean, left unchanged.
        self.abandoned = 0
        #: Components rescued by cutting the last draft at section boundaries.
        self.trimmed = 0

    def __call__(self, candidate, reflective_dataset, components_to_update) -> dict[str, str]:
        return {
            name: self._propose(candidate[name], reflective_dataset[name])
            for name in components_to_update
        }

    @staticmethod
    def _lm_call(prompt: str) -> str:
        """One reflection call, tolerating both output shapes the base LM may return.

        Mirrors `DspyAdapter.stripped_lm_call`, which is not reachable from here: the
        adapter builds it for its own default path. DSPy invokes a custom proposer
        inside `dspy.context(lm=reflection_lm)`, so `settings.lm` is already the
        reflection model — there is nothing to thread through.
        """
        raw = dspy.settings.lm(prompt)[0]
        return raw["text"] if isinstance(raw, dict) else raw

    def _propose(self, current: str, dataset_with_feedback) -> str:
        # The constraints ride along from the first attempt, not just after a
        # rejection. Stating them only in retries cost one run 8 of its 9 iterations:
        # every proposal was rejected `attempts` times, abandoned, and GEPA spent the
        # iteration re-scoring an instruction identical to the one it started with.
        document = constraint_preamble(current, self.cap)
        last = current
        for attempt in range(1, self.attempts + 1):
            proposed = InstructionProposalSignature.run(
                lm=self._lm_call,
                input_dict={
                    "current_instruction_doc": document,
                    "dataset_with_feedback": dataset_with_feedback,
                },
            )["new_instruction"]
            notes = objections(proposed, self.fields, self.cap)
            if not notes:
                return proposed
            self.rejected += 1
            # Logged as it happens, not tallied for the end. A proposer quietly
            # abandoning every iteration looks exactly like a search that has converged
            # — same score, "skipping" — and the run that hit that had no way to tell
            # the two apart until it finished.
            reasons = ", ".join(note.code for note in notes)
            print(f"    proposal rejected (attempt {attempt}/{self.attempts}): {reasons}")
            # Re-ask against the rejected draft, not the original: the next round is a
            # revision of what it just wrote, which is a smaller ask than re-deriving
            # a compliant instruction from scratch.
            document = revision_directive(proposed, notes)
            last = proposed

        # Reflectors overshoot this cap badly and do not reliably converge when asked to
        # cut — one run saw attempt 2 come back *longer* than attempt 1 despite being
        # told to delete 638 characters. So rather than throw away five reflection calls
        # and re-score the instruction we started with, cut the last draft down
        # mechanically at section boundaries and let GEPA judge the result. If the trim
        # cost quality, the candidate loses this iteration on merit; nothing unscored
        # survives it.
        if (trimmed := trim_to_fit(last, self.cap)) and not objections(
            trimmed, self.fields, self.cap
        ):
            self.trimmed += 1
            print(
                f"    trimmed the last draft to fit: {len(last)} -> {len(trimmed)} chars "
                "by dropping whole sections"
            )
            return trimmed

        self.abandoned += 1
        print("    giving up on this component; leaving the instruction unchanged")
        return current


@dataclass(frozen=True)
class ModelSpec:
    """How to reach the model standing in for the service's rewrite."""

    model: str
    api_base: str | None = None

    #: Output ceiling for the task model, and the fallback for any GEPA call that
    #: reaches for `dspy.settings.lm` instead of the reflection LM.
    #:
    #: Not sized for the answer — a cleaned transcript is a sentence or two. It is
    #: headroom for reasoning tokens, which count against the same budget on current
    #: models, and for the instruction-length proposals GEPA writes.
    #:
    #: Sized generously because truncation here is silently corrupting rather than
    #: loud. `PlainChatAdapter.parse` treats the whole completion as the answer (it
    #: has no markers to parse), so a truncated completion becomes a truncated
    #: "cleaned transcript", scores badly against its reference, and teaches GEPA
    #: that a perfectly good instruction produces bad cleanups. The run doesn't fail;
    #: it optimizes against noise. Nothing is paid for headroom left unused — the
    #: cost is in tokens generated — so the only reason to lower this is to bound a
    #: runaway, and 2048 (the previous default) was low enough that Opus 5 tripped it.
    #:
    #: Not raised further to match the reflection model: the default `--model` is a
    #: 32k-context one, and an output ceiling has to leave room for the prompt inside
    #: that window.
    max_tokens: int = 8192

    #: Output ceiling for the reflection model, which needs far more than the task
    #: model and for a different reason. It writes whole instructions, and it reasons
    #: at length before doing so — extended thinking counts against this budget, and
    #: on a frontier reflector it dominates the instruction it finally emits. 8192 was
    #: enough for the task model and not remotely enough here.
    #:
    #: Separate rather than one ceiling for both because the two models are not the
    #: same size: the task model is a small stand-in on a 32k context, so it cannot be
    #: handed a ceiling sized for a frontier reflector's thinking.
    reflection_max_tokens: int = 65536

    #: Sampling temperature for the **task** model only, or None to let the provider
    #: decide (the default, and what DSPy sends when the key is omitted).
    #:
    #: Exists for one failure mode: a small model falling into a repetition loop and
    #: generating until it hits `max_tokens`. That is not a ceiling problem — a cleaned
    #: transcript is a sentence or two — and raising the ceiling only makes each
    #: degenerate call cost more. It is also not a harmless one: `PlainChatAdapter`
    #: treats the whole completion as the answer, so the loop is scored as the cleanup.
    #:
    #: Scoped to the task model deliberately. Current Claude models reject an explicit
    #: `temperature`, and the reflection model is normally a Claude one, so setting
    #: this globally would break the reflector to fix the stand-in.
    temperature: float | None = None

    def lm(
        self,
        *,
        model: str | None = None,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> dspy.LM:
        """Build an LM, overriding the model, budget, or sampling for a secondary role.

        `temperature` is passed only when set, so the default call sends no sampling
        parameters at all — which is what keeps this usable against models that reject
        them.
        """
        kwargs: dict[str, object] = {"max_tokens": max_tokens or self.max_tokens}
        if temperature is not None:
            kwargs["temperature"] = temperature
        if self.api_base:
            kwargs["api_base"] = self.api_base
        return dspy.LM(model or self.model, **kwargs)


def configure(spec: ModelSpec) -> None:
    """Point DSPy at the model standing in for the service-side rewrite."""
    dspy.configure(lm=spec.lm(temperature=spec.temperature), adapter=PlainChatAdapter())


def optimize(
    program,
    *,
    axis: str,
    spec: ModelSpec,
    reflection_model: str | None,
    train: list[Utterance],
    validation: list[Utterance],
    auto: str,
    num_threads: int,
    proposer: CappedInstructionProposer,
    reflection_minibatch_size: int = 8,
):
    """Evolve the instruction, returning the optimized program.

    `validation` is the optimizer's own valset — the set it tracks candidates
    against while searching. It is deliberately **not** the caller's dev split: dev
    decides which instruction ships, and a set that steered the search cannot also
    judge it without flattering whatever the search overfit.

    The length cap reaches it twice: as prose in the proposer's preamble, which only
    asks, and as `proposer`'s rejection of anything that does not fit, which does not.
    The rejection is the constraint; the prose makes the first attempt likelier to
    land and so saves retries. The caller length-checks the winner regardless.

    MIPROv2 was offered alongside this and has been removed. It searches on a bare
    scalar and exposes no proposal hook, so the cap could not constrain its search at
    all — only refuse its output afterwards — and its multi-field proposal prompts go
    through the configured adapter, which for a small `--model` means the marker
    protocol that model cannot follow.
    """
    trainset, valset = to_examples(train), to_examples(validation)
    return dspy.GEPA(
        metric=make_feedback_metric(axis),
        auto=auto,
        # Never below the task model's ceiling: the reflector writes whole
        # instructions and thinks at length first, so it is the call most likely
        # to need the room, and raising --max-tokens should never leave it as the
        # tighter of the two.
        reflection_lm=spec.lm(
            model=reflection_model,
            max_tokens=max(spec.reflection_max_tokens, spec.max_tokens),
        ),
        num_threads=num_threads,
        instruction_proposer=proposer,
        # What a crashed rollout is worth. It has to sit at or below the worst a
        # real output can reach, or a candidate that errors would outrank one that
        # merely answered badly. GEPA's default is 0.0, which was right only while
        # the score was floored there; now that a degenerate output can reach -1,
        # a crash has to go with it.
        failure_score=metrics.WORST_SCORE,
        # Crossover needs components to cross over. This program has exactly one
        # predictor, and merge recombines by taking, per predictor, whichever
        # parent differs from the common ancestor — so with a single component the
        # "merged" candidate is byte-identical to one of its parents. GEPA's
        # default leaves it on, which buys up to `max_merge_invocations` duplicate
        # programs, each scheduled and evaluated for nothing. Off, that budget goes
        # to reflection trials instead.
        #
        # It was never a *correctness* risk: merge writes no text (it makes no LM
        # call at all), so it can only copy instructions the proposer already
        # cleared. Revisit if the program ever grows a second predictor.
        use_merge=False,
        # How many scored examples the reflector sees before rewriting. GEPA's
        # own default is 3, which on a task this well-solved often means three
        # near-perfect examples and almost no failure to generalise from — the
        # reflector is then rewriting on the strength of one bad case, or none.
        # These are cheap next to the periodic full-valset evals.
        reflection_minibatch_size=reflection_minibatch_size,
    ).compile(program, trainset=trainset, valset=valset)
