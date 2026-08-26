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
and fixes punctuation before the text is pasted. Blurt sends `candidates.PRIOR_WINNER`
there (as `CleanupInstruction.text` on the Swift side); before that it sent an empty
`llm` object, which selects the service's own default wording. This script searches
for an instruction that beats the one shipping now.

How it measures that
--------------------
By default it uses a **real paired corpus**: `nyra`, which ships each utterance twice
— as the speaker said it and as they meant it — from Switchboard conversations whose
disfluencies trained annotators marked by hand.
Candidates are scored on how closely their output restores the intended side
(`metrics.py`). `--source builtin` swaps in a bundled sample made disfluent
synthetically (`disfluency.py`) for the offline path. See `corpus.py` for what each
source can and cannot measure.

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
doesn't fit isn't a winner. Three places enforce that, because none is sufficient
alone: the hand-written candidates are checked before any model call;
`program.CappedInstructionProposer` states the budget in its preamble and then
rejects and re-asks any proposal that misses it, which is what makes the cap a
constraint on the *search* rather than a verdict on its output; and an over-cap
result is refused at selection no matter how well it scored.

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
import spoken_punctuation  # noqa: E402
from candidates import (  # noqa: E402
    BASELINE,
    CANDIDATES,
    INSTRUCTION_CHARACTER_CAP,
    SPOKEN_PUNCTUATION_CANDIDATES,
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


def print_command_table(rows: list[tuple[str, dict[str, float]]], axis: str) -> None:
    """What became of the planted commands, per candidate.

    Printed apart from the axis table because it answers a different question. WER says
    how close the text came; this says how many of the commands actually planted were
    obeyed, left in the output as words, or silently dropped — and `literal` is the one
    that reaches the user's document as visible nonsense, so it earns its own column
    rather than being folded into "did not convert".

    Ordered by the selecting axis, not by conversion rate, so a candidate that converts
    more commands and still loses is visible as exactly that.
    """
    scored = [row for row in rows if row[1].get("commands_total")]
    if not scored:
        return
    print("\nSpoken punctuation commands, per candidate")
    print(
        f"  {'candidate':<22} {'converted':>10} {'left as words':>14} {'dropped':>9}"
        f" {'ROWS wrong':>11} {'ROWS w/ word':>13}"
    )
    print(f"  {'-' * 22} {'-' * 10} {'-' * 14} {'-' * 9} {'-' * 11} {'-' * 13}")
    for name, scores in sorted(scored, key=lambda row: row[1][axis], reverse=True):
        print(
            f"  {name:<22} {scores['commands_converted']:>10.1%} "
            f"{scores['commands_literal']:>14.1%} {scores['commands_missing']:>9.1%}"
            f" {scores.get('rows_with_command_failure', 0.0):>11.1%}"
            f" {scores.get('rows_with_command_literal', 0.0):>13.1%}"
        )
    print(
        "  The last two columns are per utterance, not per command: how often a dictation\n"
        "  comes back with any command missed, and how often it comes back with a command\n"
        "  word pasted into it. A per-command mean cannot tell you either."
    )


def print_samples(loaded: corpus.Corpus, count: int) -> None:
    print(f"\nExamples (showing {min(count, len(loaded))} of {len(loaded)})")
    for utterance in loaded.utterances[:count]:
        floor = utterance.scored(utterance.disfluent)
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
        default="nyra",
        choices=(*corpus.SOURCES, "builtin", "punctuation"),
        help="which corpus to score against (default: nyra, the same hand-annotated "
        "Switchboard pairs with casing repaired, so the formatting axis is live and "
        "--metric blend scores two axes instead of degrading to content). builtin is a "
        "bundled sample made disfluent by the injector, for the offline path. punctuation is "
        "a second bundled sample written for --punctuation-only: every row carries an "
        "internal mark, because a dictated mark on the last word is one any instruction "
        "would produce unprompted",
    )
    data.add_argument(
        "--limit",
        type=int,
        default=4000,
        help="how many pairs to load (default: 4000, most of nyra's 4458-row train split). "
        "Everything past --dev-fraction and "
        "--test-fraction becomes train, and train rows are the free ones: GEPA draws a "
        "fixed number of fixed-size reflection minibatches however large the trainset is, "
        "so raising this buys more varied feedback at no extra model cost. The ceiling is "
        "the corpus (nyra is ~5k utterances) and the datasets-server rate "
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

    spoken = parser.add_argument_group("spoken punctuation (any source)")
    spoken.add_argument(
        "--spoken-punctuation",
        type=float,
        default=None,
        metavar="RATE",
        help="0..1; speak this share of the punctuation the reference licenses, turning "
        'each mark into the words a dictation user says out loud ("comma", "question '
        'mark", "all caps"). Defaults to 0 — off — or to 1.0 under --punctuation-only. Unlike --severity this applies to a '
        "PAIRED source too: the marks come from the corpus's own clean side, so the "
        "disfluencies stay the ones annotators marked by hand and only the punctuation "
        "task is synthetic. Below 1 on purpose — a corpus with no real marks left in the "
        "input teaches an instruction to punctuate by guesswork instead of by command",
    )
    spoken.add_argument(
        "--spoken-caps-rate",
        type=float,
        default=0.25,
        metavar="RATE",
        help="0..1; chance a row also gets one ALL CAPS command (default: 0.25). At most "
        "one per row — two in a 15-word utterance would make the operator most of the "
        "corpus. Only this operator edits the reference, because a target with no "
        "uppercase in it cannot pose the task. Ignored unless --spoken-punctuation is on",
    )
    spoken.add_argument(
        "--punctuation-only",
        action="store_true",
        help="score ONLY the punctuation commands. The input then differs from the target "
        "by nothing but the commands: no disfluencies are injected, and a paired source's "
        "verbatim side is discarded in favour of its clean one, so nothing a cleanup does "
        "about hesitation can move the number. Every row is guaranteed at least one "
        "command and rows the injector cannot plant one in are dropped. Implies "
        "--spoken-punctuation 1.0 unless you pass a rate; the utterance-final mark is "
        "never spoken even then, so each row still contains real punctuation the "
        "instruction has to leave alone",
    )

    evaluation = parser.add_argument_group("evaluation")
    evaluation.add_argument(
        "--metric",
        default=None,
        choices=metrics.AXES,
        help="which axis selects the winner. Default: blend (0.7 content / 0.3 format), "
        "or format under --spoken-punctuation. Spoken punctuation is a formatting task "
        "that content cannot see — normalize() casefolds and strips marks, so a restored "
        "comma and a missed one are the same string to it, and an ALL CAPS command is "
        "invisible. format is the axis that sees the whole task, and it still sees the "
        "expensive failure (a command left in as a word) as an inserted token",
    )
    evaluation.add_argument(
        "--dev-fraction",
        type=float,
        default=900,
        metavar="ROWS_OR_FRACTION",
        help="dev rows, absolute at 1 or above and a fraction below (default: 900). Dev "
        "decides which instruction ships — baseline versus the optimizer's result — and "
        "the optimizer never sees it: its own valset is carved from train instead "
        "(--gepa-valset). Sized for resolution: a search once won by +0.008 on 50 valset "
        "rows and lost by 0.006 on 150 dev rows, both inside the noise, so the binding "
        "constraint on finding a winner is how finely the difference can be measured. Tripled "
        "from 300 after a --auto heavy search came in 0.001 behind its seed — a verdict that "
        "cost 27 reflection trials and could not be trusted either way",
    )
    evaluation.add_argument(
        "--gepa-valset",
        type=float,
        default=450,
        metavar="ROWS_OR_FRACTION",
        help="rows taken off train for the optimizer's own valset (default: 450). GEPA "
        "scores every surviving candidate against all of it, so its size multiplies the "
        "search's cost while buying no exploration — that depends only on --auto. GEPA's "
        "own advice is the smallest set that still matches the task distribution, and 50 "
        "was that; it was raised to 150 because at 50 the Pareto front was ranking candidates "
        "on differences it could not resolve, and picking a winner that dev then rejected, and "
        # `%%` because argparse %-expands help strings against a dict of params, so a bare
        # `%` raises TypeError and `--help` fails outright — which it did, from the day
        # this figure was written until someone tried to read the help.
        "tripled again alongside dev. Noise falls as the square root, so 3x the rows is ~42%% "
        "less of it — nothing cheaper buys that",
    )
    evaluation.add_argument(
        "--test-fraction",
        type=float,
        default=450,
        metavar="ROWS_OR_FRACTION",
        help="held-out rows, absolute at 1 or above and a fraction below (default: 450). "
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
        "in the loop. The `openai/` prefix is LiteLLM routing and is stripped before the "
        "gateway sees it, so the id it receives is the bare one. Pass the same id as "
        "--model to collapse them",
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
    search = parser.add_argument_group("search")
    search.add_argument(
        "--optimizer",
        default="gepa",
        choices=("none", "gepa"),
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
        "--baseline",
        default=BASELINE,
        metavar="NAME",
        help=f"which instruction is the bar (default: {BASELINE}, what Blurt ships). It is "
        "the row the winner is scored against on held-out test, what --candidates baseline "
        "scores, and the one instruction held to the safeguard requirement. Point it at a "
        "candidate that has already won a round and the run stops re-measuring something "
        "you know: a search whose bar is still the shipped string spends a dev sweep "
        "confirming the shipped string. candidates.BASELINE itself does not move, because "
        "it is what the Swift side actually sends",
    )
    search.add_argument(
        "--start",
        default="prior-winner",
        metavar="prior-winner|best-candidate|NAME",
        help="which instruction the optimizer starts from (default: prior-winner, the "
        "evolved instruction in candidates.py — it already scores well and only needs "
        "pruning under the character cap; best-candidate starts from whichever "
        "hand-written candidate topped dev instead). Any candidate name also works, which "
        "is how a search picks up where a ranking run left off: --start punct-explicit "
        "--candidates baseline skips a sweep you have already paid for",
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
        help="also run the same audio with an empty llm block, which selects the service's "
        "own default wording — what Blurt sent before it began sending an instruction. This "
        "is the comparison the text harness cannot make: guessed-default only ever guessed "
        "at that wording, and this uses the wording itself",
    )

    parser.add_argument(
        "--dump-corpus",
        default=None,
        metavar="PATH",
        help="write the loaded corpus to PATH as JSONL and carry on. Reading it back with "
        "--jsonl reproduces it exactly, commands and all, so a dataset can be frozen in "
        "the tree and diffed instead of re-derived from a download plus two seeded "
        "injectors. Works under --dry-run, so generating one needs no API key. Mind the "
        "licensing: --source builtin is written for this repo, while nyra derives from "
        "LDC-licensed Switchboard transcripts and should stay out of version control",
    )
    parser.add_argument("--out", default=None, help="write the full results as JSON to this path")
    args = parser.parse_args(argv)
    # `--punctuation-only` without a rate would load a corpus with no commands in it,
    # which is the opposite of what it asks for. Resolved here rather than in `main` so
    # anything reading `parse_args` sees the same coupling.
    if args.spoken_punctuation is None:
        args.spoken_punctuation = 1.0 if args.punctuation_only else 0.0
    return args


#: Axis each corpus shape selects on when `--metric` is not given.
DEFAULT_AXIS = "blend"
SPOKEN_PUNCTUATION_AXIS = "format"


def instruction_table(loaded: corpus.Corpus) -> dict[str, str]:
    """The instructions this run scores — the shipped set, plus the task's own.

    `SPOKEN_PUNCTUATION_CANDIDATES` are merged in rather than living in `CANDIDATES`
    because they are dead weight on every ordinary run: a punctuation clause cannot help
    against a corpus that poses no punctuation commands, and each one costs a full dev
    sweep to re-rank. `BASELINE` is untouched either way, so the held-out comparison is
    still against what Blurt ships.

    Keyed on the loaded corpus rather than on `--spoken-punctuation`, so a frozen dataset
    read back with `--jsonl` is scored the same way as the corpus it was dumped from: it
    carries the commands and not the flag.
    """
    if not loaded.has_commands:
        return dict(CANDIDATES)
    return dict(CANDIDATES) | SPOKEN_PUNCTUATION_CANDIDATES


def describe_length(instruction: str) -> str:
    """`2048 chars` plus how that sits against the cap — the line every report ends on."""
    over = overage(instruction)
    if over:
        return f"{len(instruction)} chars — {over} OVER the {INSTRUCTION_CHARACTER_CAP} cap"
    headroom = INSTRUCTION_CHARACTER_CAP - len(instruction)
    return f"{len(instruction)} chars, {headroom} under the {INSTRUCTION_CHARACTER_CAP} cap"


def check_candidates(table: dict[str, str] | None = None, baseline: str = BASELINE) -> None:
    """Refuse to start if a hand-written candidate could never be shipped.

    Before any model call, because these are typo-class mistakes and paying for a full
    sweep to discover one is pure waste. Nothing is exempt, `prior-winner` included:
    it earned its place in the table by being compressed under the cap, and if a later
    edit pushes it back over — or strips a safeguard — this is what says so.

    Only `BASELINE` is held to the safeguard requirement. The other candidates are
    deliberately terse one-liners whose job is to be *contrast* — `guessed-default` is
    a floor, not something anyone would ship — and demanding the full safeguard set of
    them would turn the comparison set into six copies of the same careful paragraph.

    Takes the table rather than reading `CANDIDATES` so that whatever
    `instruction_table` merged in is checked too; omitting it checks the shipped set. A `--spoken-punctuation` candidate is
    exactly as capable of being 8 characters over the cap as any other — `punct-appended`
    lands at 2006 of 2048 — and discovering that after paying for a dev sweep is the
    waste this function exists to prevent.
    """
    problems: list[str] = []
    for name, text in (CANDIDATES if table is None else table).items():
        if overage(text):
            problems.append(f"  {name}: {describe_length(text)}")
        if name == baseline and (absent := missing_safeguards(text)):
            stems = ", ".join(stem for stem, _ in absent)
            problems.append(f"  {name}: the baseline is missing safeguard(s): {stems}")
    if problems:
        raise SystemExit(
            "These candidates.py instructions could not be shipped as written:\n"
            + "\n".join(problems)
        )


def resolve_candidates(
    args: argparse.Namespace,
    table: dict[str, str] | None = None,
    spoken: bool = False,
) -> list[str]:
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

    A `spoken` corpus gets a **third** answer: the punctuation candidates plus
    `BASELINE`, and not the six terse contrast instructions. `BASELINE` alone is not
    enough — it has never heard of the task, so a search seeded from it starts outside
    the region worth exploring — but the six one-liners are worse than useless here. They
    exist to rank framings of *disfluency* cleanup ("verbatim-preserving" against
    "dictation-intent"), none of them mentions punctuation, and every one of them will
    land near the floor for the same reason. At the default 900-row dev split that
    ordering costs 5,400 model calls to re-discover. `--candidates all` still buys them
    if you want to see it happen.
    """
    if args.candidates == "all":
        return list(CANDIDATES if table is None else table)
    # Honoured on a spoken run too. It was not, which made the flag a lie exactly when it
    # was worth using: on a large corpus the sweep is `len(scoring) x dev` calls, and
    # having already run it once, paying for it again to reach the search is the one thing
    # anyone would reach for this flag to avoid.
    baseline = getattr(args, "baseline", BASELINE)
    if args.candidates == "baseline":
        return [baseline]
    if spoken:
        # The bar first, so the table reads as "the bar, then the challengers" — and
        # de-duplicated, since a baseline promoted from a previous round is itself one of
        # them and would otherwise be scored twice.
        return [baseline, *(n for n in SPOKEN_PUNCTUATION_CANDIDATES if n != baseline)]
    if (
        args.candidates is None
        and args.optimizer == "none"
        # Nothing has been scored yet, so "best" is unknowable without the sweep.
        or args.start == "best-candidate"
    ):
        return list(CANDIDATES if table is None else table)
    return [baseline]


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
        # `None` sends an empty llm block — the service's own default wording, which no
        # text-only candidate can stand in for.
        runs.append(("service default (empty llm)", None))

    summaries: dict[str, dict[str, float]] = {}
    try:
        # Synthesized once and replayed, so both runs hear byte-identical audio and the
        # `say`/`afconvert` work is not repeated per candidate.
        spoken = live.synthesize_all(sample)
        with Progress(len(runs) * len(sample), "Verifying against the real endpoint") as meter:
            for name, instruction in runs:
                results = live.verify(
                    spoken, instruction, api_key, on_example=lambda n=name: meter.tick(n)
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


def resolve_axis(requested: str | None, loaded: corpus.Corpus) -> str:
    """Refuse to select on an axis the corpus cannot measure.

    Some corpora carry casing or punctuation their targets did not intend — most
    often because the clean side was produced by mechanically deleting spans, which
    strands the following word in lowercase. Scoring formatting against that
    penalizes a *correct* cleanup, so `blend` degrades to `content` with a note and
    an explicit `--metric format` is an error rather than a meaningless number.

    `requested` is None when `--metric` was not given, which is where the default lives
    rather than in `argparse`: it depends on whether the corpus poses punctuation
    commands. A `--spoken-punctuation` corpus that also cannot be scored on formatting
    fails below rather than quietly selecting on content, because content cannot see an
    ALL CAPS command at all and half the task would go unmeasured.
    """
    if requested is None:
        requested = SPOKEN_PUNCTUATION_AXIS if loaded.has_commands else DEFAULT_AXIS
    if loaded.formatting_is_measurable or requested == "content":
        return requested
    if requested == "format":
        raise SystemExit(
            f"--metric format needs a corpus with trustworthy target formatting; "
            f"{loaded.source} does not have it. Use --source nyra for repaired casing, or "
            "--source builtin --strip-formatting to pose formatting restoration as a task."
            + (
                " Spoken punctuation needs it too: the commands it plants are answered "
                "in capitalization and marks, which the content axis cannot see."
                if loaded.has_commands
                else ""
            )
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
        limit=args.limit,
        split=args.split,
        jsonl=args.jsonl,
        seed=args.seed,
        severity=args.severity,
        strip_formatting=args.strip_formatting,
        spoken_punctuation_rate=args.spoken_punctuation,
        spoken_caps_rate=args.spoken_caps_rate,
        punctuation_only=args.punctuation_only,
    )
    print(f"Loaded {len(loaded)} pairs from {loaded.source}: {loaded.detail}")
    print(f"{loaded.disfluent_fraction:.0%} of pairs differ from their target")

    # After the load, because which instructions are in play depends on whether the
    # corpus poses the punctuation task — and a `--jsonl` dataset answers that by what it
    # contains, not by a flag. Still before any model call, which is what the check is
    # for: a typo in candidates.py should not cost a paid sweep to discover.
    table = instruction_table(loaded)
    check_candidates(table, args.baseline)
    if args.baseline not in table:
        raise SystemExit(
            f"--baseline {args.baseline!r} is not a candidate this run scores. Available: "
            + ", ".join(table)
        )
    if args.start != "best-candidate" and args.start not in table:
        raise SystemExit(
            f"--start {args.start!r} is not a candidate this run scores. Available: "
            + ", ".join(("best-candidate", *table))
        )

    train, dev, test = corpus.split(
        list(loaded.utterances), args.seed, args.dev_fraction, args.test_fraction
    )
    # The optimizer's valset comes off train, not out of dev. Three sets, three jobs:
    # the search tracks candidates against `validation`, dev decides which instruction
    # ships, and test is the number reported. Carving the valset from dev instead —
    # which is what this did until the sets were separated — leaves the set that
    # steered the search also judging it, and a search that overfits 50 rows then
    # reports its overfitting as a win.
    validation, train = corpus.carve_validation(train, args.gepa_valset)
    print(
        f"Split: {len(train)} train / {len(validation)} optimizer valset / "
        f"{len(dev)} dev / {len(test)} test"
    )

    if args.dump_corpus:
        written = corpus.dump_jsonl(loaded, args.dump_corpus)
        print(f"\nWrote {written} rows to {args.dump_corpus}")

    if args.show_samples:
        print_samples(loaded, args.show_samples)

    axis = resolve_axis(args.metric, loaded)
    # Written back so the results file records the axis the run actually selected on
    # rather than the `None` that means "let the corpus decide".
    args.metric = axis
    floors = {"dev": corpus.no_cleanup_floor(dev), "test": corpus.no_cleanup_floor(test)}
    print(
        f"\nNo-cleanup floor ({axis}) — the corpus's disfluent side scored against its "
        f"own target, no model involved: dev {floors['dev'][axis]:.4f}, "
        f"test {floors['test'][axis]:.4f}"
    )
    print(
        f"A false start left uncorrected costs {metrics.FALSE_START_WEIGHT:g} errors per word "
        f"rather than one; {corpus.false_start_fraction(dev):.0%} of dev rows and "
        f"{corpus.false_start_fraction(test):.0%} of test rows contain one"
    )
    if loaded.has_commands:
        planted = sum(len(u.commands) for u in dev + test)
        print(
            f"\nSpoken punctuation: {planted} commands planted across {len(dev) + len(test)} "
            f"dev+test rows ({planted / max(1, len(dev) + len(test)):.2f} per row); "
            f"{sum(bool(u.commands) for u in dev + test) / max(1, len(dev) + len(test)):.0%} "
            "of rows carry at least one"
        )
        # Bounds what the run can say about over-conversion, so it is printed rather
        # than left to be assumed away. See spoken_punctuation.literal_use_fraction.
        literal = spoken_punctuation.literal_use_fraction(u.reference for u in dev + test)
        print(
            f"{literal:.1%} of those references use a command phrase as ordinary content, so "
            "the score is nearly blind to an instruction that converts 'the Cretaceous "
            "period'. That clause is in the candidates on product grounds, not scored ones"
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
    program.configure(spec)

    scoring = resolve_candidates(args, table, spoken=loaded.has_commands)
    dev_rows: list[tuple[str, dict[str, float]]] = []
    with Progress(len(scoring) * len(dev), "Scoring candidates on dev") as meter:
        for index, name in enumerate(scoring, start=1):
            note = f"{name} ({index}/{len(scoring)})"
            scores = program.evaluate(
                program.build(table[name]),
                dev,
                args.num_threads,
                on_example=lambda n=note: meter.tick(n),
            )
            dev_rows.append((name, scores))
    print_table(dev_rows, f"Candidate instructions on dev, selecting on {axis}", axis)
    print_command_table(dev_rows, axis)

    winner_name, winner_scores = max(dev_rows, key=lambda row: row[1][axis])
    winner_instruction = table[winner_name]

    if args.optimizer != "none":
        # The seed is an ordinary candidate — it fits the cap, so it was scored in the
        # sweep above and may legitimately win. Nothing to score separately, and no
        # need to keep it out of the selection: unlike the over-cap instruction this
        # replaced, shipping it is a real option.
        seed_name = winner_name if args.start == "best-candidate" else args.start
        seed_instruction = table[seed_name]
        scored_on_dev = dict(dev_rows)
        if seed_name in scored_on_dev:
            seed_scores = scored_on_dev[seed_name]
        else:
            # The resume path: `--candidates baseline --start NAME` deliberately skips the
            # sweep, so the seed has no dev score yet — and the seed is precisely what the
            # search's result has to be measured against, since "did evolving this beat
            # starting from it" is the question. One dev sweep instead of the whole table's.
            with Progress(len(dev), f"Scoring the seed {seed_name} on dev") as meter:
                seed_scores = program.evaluate(
                    program.build(seed_instruction), dev, args.num_threads, on_example=meter.tick
                )
            dev_rows.append((seed_name, seed_scores))
            # Recomputed, because the seed may well beat what the sweep scored: if the
            # search then fails, the fallback should be the better of the two rather than
            # whichever happened to be measured first.
            winner_name, winner_scores = max(dev_rows, key=lambda row: row[1][axis])
            winner_instruction = table[winner_name]

        proposer = program.CappedInstructionProposer(INSTRUCTION_CHARACTER_CAP)

        print(f"\nRunning {args.optimizer} from {seed_name} ({describe_length(seed_instruction)})…")
        optimized = program.optimize(
            program.build(seed_instruction),
            axis=axis,
            spec=spec,
            reflection_model=args.reflection_model,
            train=train,
            validation=validation,
            auto=args.auto,
            num_threads=args.num_threads,
            proposer=proposer,
            reflection_minibatch_size=args.reflection_minibatch_size,
        )
        optimized_instruction = optimized.signature.instructions
        if proposer.rejected:
            # A search that spent itself fighting the cap should be visible, not
            # inferred from a disappointing score.
            print(
                f"\nThe proposer rejected {proposer.rejected} unshippable proposal(s): "
                f"{proposer.trimmed} were rescued by trimming whole sections, "
                f"{proposer.abandoned} were abandoned and left unchanged after the retries. "
                "A high abandoned count means the search spent its iterations re-scoring the "
                "instruction it started from."
            )
        with Progress(len(dev), "Re-scoring the optimized instruction") as meter:
            optimized_scores = program.evaluate(
                optimized, dev, args.num_threads, on_example=meter.tick
            )
        optimized_name = f"{args.optimizer}-optimized"
        dev_rows.append((optimized_name, optimized_scores))
        print_table(dev_rows, f"With the optimized instruction, on dev ({axis})", axis)
        print_command_table(dev_rows, axis)
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
        # The proposer's own configuration, so the in-search gate and this one cannot
        # disagree — it previously respelled the fields and omitted the cap entirely,
        # falling back to the module default rather than the cap the search ran under.
        final_objections = objections(optimized_instruction, proposer.fields, proposer.cap)
        if final_objections:
            listed = "\n".join(f"  - {note.message}" for note in final_objections)
            print(
                f"\nRefusing to select it. Keeping {winner_name}.\n{listed}\n"
                "The search is stochastic, so re-running is worth a try; --auto heavy buys "
                "more of it, and --start best-candidate begins from a short instruction "
                "instead of asking the reflector to cut a long one down."
            )
        elif optimized_scores[axis] > winner_scores[axis]:
            winner_name = optimized_name
            winner_instruction = optimized_instruction
        else:
            print(
                f"\n{args.optimizer} did not beat {winner_name} on dev; keeping the hand-written one."
            )

    # Held-out test scores for the winner and for the shipped-default proxy, so the
    # reported improvement is measured on data no selection decision saw.
    scored_on_test = [(winner_name, winner_instruction)]
    if winner_name != args.baseline:
        scored_on_test.append((args.baseline, table[args.baseline]))
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
    print_command_table(test_rows, axis)

    live_summary = run_live_verification(args, winner_name, winner_instruction, test)

    print(f"\nBest cleanup instruction ({describe_length(winner_instruction)}):\n")
    print(f"  {winner_instruction}\n")
    print(
        "Ship it by replacing `CleanupInstruction.text` in\n"
        "  Sources/BlurtEngine/STT/CleanupInstruction.swift, which is what\n"
        "`AssemblyAITranscriber`'s `LLMRewrite` sends as `config.llm.instruction`.\n"
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
            "candidates": table,
        }
        Path(args.out).write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        print(f"\nWrote {args.out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
