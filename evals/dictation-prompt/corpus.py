"""Where the eval's (disfluent input, clean target) pairs come from.

Two kinds of source, both yielding the same `Utterance`:

**Paired** — a dataset that already ships both sides. These are the ones to
prefer: the disfluencies are the ones real speakers produced, not the ones we
thought to write down.

- `disfluency-speech` (default) — `amaai-lab/DisfluencySpeech`, ~5k utterances
  from a single speaker re-recording ~10 hours of real Switchboard telephone
  conversations. Its `transcript_annotated` column carries Switchboard's own
  disfluency markup (`{D}` discourse marker, `{F}` filled pause, `{E}` editing
  term, `[ reparandum + repair ]`), which trained annotators produced by hand
  under the LDC stylebook; the `transcript_a`/`_b`/`_c` columns are that markup
  mechanically stripped at three levels. We score `transcript_a` (every word as
  spoken, non-speech events removed — exactly the shape a transcriber emits, with
  cut-offs already written `bam-`) against `transcript_c` (filled pauses, editing
  terms, discourse markers, and false starts all gone).

  The catch is that stripping is mechanical, so a removed sentence-initial
  discourse marker leaves the next word lowercase (`Yeah. rabbits are darling`).
  Targets are therefore unreliable on capitalization and the formatting axis is
  disabled here — a correct cleanup would be *penalized* for writing `Rabbits`.
- `nyra` — `nyralabs/disfluency_speech_english`, the same corpus repackaged as
  `verbatim_transcript` / `intended_transcript` with the casing repaired, which is
  why formatting *is* measurable here. It costs some fidelity: it retains
  repetitions the hand annotation marked as reparanda, and rewrites the verbatim
  side into its own conventions (`[UH]`, `[laughter]`, `th*`), which `_detag_nyra`
  has to undo. Use it when the formatting axis matters more than exact recall.
- `disfl-qa` — `google-research-datasets/disfl_qa`, ~12k SQuAD questions with a
  human-written disfluent variant. Over 90% of its disfluencies are corrections
  and restarts, deliberately the *hard* cases (Switchboard is over half simple
  repetitions), so it complements the two above rather than duplicating them.
  Both sides are properly written, so the formatting axis is live but undemanding.

**Reference-only** — clean transcripts that the injector turns into pairs
(`disfluency.py`). `fleurs` is `google/fleurs`, whose `raw_transcription` field
keeps real casing and punctuation (the sibling `transcription` field is normalized
to lowercase, which would make the formatting axis meaningless). Read speech, so
it carries essentially no natural disfluencies of its own — which is the point:
everything disfluent about it is under our control, including whether punctuation
survives. `builtin` is a small bundled sample for the offline path.

`--jsonl` reads a local file, accepting either shape: objects with both
`disfluent` and `reference` are used as-is, anything with only a reference goes
through the injector.

Dataset rows arrive over the Hugging Face datasets-server rows API, which returns
audio columns as URLs rather than bytes — a few hundred transcripts cost a few
hundred kilobytes and no extra dependency. `--loader datasets` switches to the
library for gated sets where the rows API needs credentials it already has.
"""

from __future__ import annotations

import json
import os
import pathlib
import random
import re
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field, replace

import disfluency
import metrics

ROWS_API = "https://datasets-server.huggingface.co/rows"

# Utterance-length window, in words of the reference. The floor drops examples too
# short for a disfluency to matter; the ceiling drops material that stops looking
# like one dictated burst and would let a few long outliers dominate the mean.
MIN_WORDS = 3
MAX_WORDS = 60

# Reference-only sources feed the injector, which needs room to work and — for the
# formatting axis to mean anything — a reference that is actually punctuated.
MIN_WORDS_FOR_INJECTION = 8

_TAG = re.compile(r"\[([A-Za-z_]+)\]")
_CUTOFF = re.compile(r"\b([A-Za-z]+)\*")
# The two bracketed tags that stand for words the speaker said; every other tag is
# a non-speech event (laughter, breath, cough) that a transcriber would not emit.
_SPOKEN_TAGS = {"uh": "uh", "um": "um"}


def _detag_nyra(text: str) -> str:
    """Rewrite the corpus's annotation conventions as ordinary transcript text.

    `[UH] ... th* ... [laughter]` becomes `uh ... th- ...`, so the model sees what
    a speech-to-text service would actually hand it rather than a labelling scheme.
    Applied to both sides: the target should not contain tags either.
    """
    text = _TAG.sub(lambda m: _SPOKEN_TAGS.get(m.group(1).lower(), ""), text)
    text = _CUTOFF.sub(lambda m: f"{m.group(1)}-", text)
    return re.sub(r"\s+", " ", text).strip()


@dataclass(frozen=True)
class Source:
    """One place pairs can come from, and what the corpus it yields supports."""

    key: str
    dataset: str
    split: str
    config: str | None = None
    # Paired sources name both columns; reference-only sources name just the one.
    input_field: str | None = None
    target_field: str = ""
    detag: Callable[[str], str] | None = None
    # False when the reference side carries no capitalization or punctuation, so
    # the formatting axis would score noise.
    formatting_is_measurable: bool = True
    note: str = ""

    @property
    def is_paired(self) -> bool:
        return self.input_field is not None

    @property
    def fields(self) -> tuple[str, ...]:
        return (self.input_field, self.target_field) if self.is_paired else (self.target_field,)


SOURCES: dict[str, Source] = {
    "disfluency-speech": Source(
        key="disfluency-speech",
        dataset="amaai-lab/DisfluencySpeech",
        split="test",
        input_field="transcript_a",
        target_field="transcript_c",
        # transcript_a is already exactly what a transcriber emits — words as
        # spoken, non-speech events dropped, cut-offs written `bam-`. No rewriting
        # needed, unlike the nyra repackaging below.
        formatting_is_measurable=False,
        note=(
            "hand-annotated Switchboard disfluencies; transcript_a (as spoken) -> "
            "transcript_c (false starts removed). Targets carry mechanical casing "
            "artifacts, so only content is scored"
        ),
    ),
    "nyra": Source(
        key="nyra",
        dataset="nyralabs/disfluency_speech_english",
        split="test",
        input_field="verbatim_transcript",
        target_field="intended_transcript",
        detag=_detag_nyra,
        note="the same corpus recased and repunctuated, at the cost of some fidelity",
    ),
    "disfl-qa": Source(
        key="disfl-qa",
        dataset="google-research-datasets/disfl_qa",
        split="test",
        input_field="disfluent question",
        target_field="original question",
        note="human-written disfluencies, mostly corrections and restarts",
    ),
    "fleurs": Source(
        key="fleurs",
        dataset="google/fleurs",
        config="en_us",
        split="test",
        target_field="raw_transcription",
        note="clean read speech; disfluencies are injected synthetically",
    ),
}

# Stand-in corpus for `--source builtin`. Written for this repo (not drawn from any
# dataset) so the offline path carries no third-party licensing.
BUILTIN_SAMPLE: tuple[str, ...] = (
    "The build failed because the signing certificate expired over the weekend.",
    "Can you send me the latest numbers before the review meeting tomorrow morning?",
    "I think we should ship the fix behind a flag and watch the crash rate for a day.",
    "The microphone permission dialog never appears when the app runs from a temporary directory.",
    "Let's move the retrospective to Thursday so everyone in Berlin can attend.",
    "She pointed out that the transcript is already punctuated when it comes back from the service.",
    "We measured about a hundred and seventy milliseconds of connection setup on a cold start.",
    "The overlay should stay on screen until the paste actually lands in the target application.",
    "Nobody has looked at the notarization logs since the last release went out.",
    "It turns out the regression was introduced by the change to the clipboard restore path.",
    "Please double check the sample rate before you send the audio to the transcription endpoint.",
    "The design review is blocked on whether we keep the menu bar item at all.",
)


@dataclass(frozen=True)
class Utterance:
    """One eval example: what the model is given, and what it should produce."""

    reference: str
    disfluent: str
    # Injector operators, empty for a real paired corpus — nobody annotated those.
    operations: tuple[str, ...] = field(default=())

    @property
    def is_disfluent(self) -> bool:
        """False when input and target already match — a don't-over-edit example."""
        return metrics.normalize(self.disfluent) != metrics.normalize(self.reference)


@dataclass(frozen=True)
class Corpus:
    """Loaded pairs plus where they came from, for the results file."""

    utterances: tuple[Utterance, ...]
    source: str
    detail: dict[str, object]
    formatting_is_measurable: bool = True

    def __len__(self) -> int:
        return len(self.utterances)

    @property
    def disfluent_fraction(self) -> float:
        """Share of examples whose input actually differs from its target."""
        if not self.utterances:
            return 0.0
        return sum(u.is_disfluent for u in self.utterances) / len(self.utterances)


def _tidy(text: object) -> str:
    return " ".join(text.split()) if isinstance(text, str) else ""


def _usable_reference(text: str, *, for_injection: bool) -> bool:
    """Is this reference worth keeping as a target?"""
    words = len(text.split())
    floor = MIN_WORDS_FOR_INJECTION if for_injection else MIN_WORDS
    if not floor <= words <= MAX_WORDS:
        return False
    # A reference with no terminal punctuation is a truncated or normalized
    # transcript; injecting into it and then scoring punctuation restoration
    # against it would penalize a correct cleanup.
    return not for_injection or text[-1] in ".?!"


def _collect(pairs, limit: int, *, for_injection: bool) -> list[Utterance]:
    """Filter, de-duplicate by reference, and cap — the one copy of that policy.

    Consumes lazily, so a paging loader stops fetching as soon as `limit` usable
    pairs have been found.
    """
    seen: set[str] = set()
    kept: list[Utterance] = []
    for disfluent, reference in pairs:
        reference, disfluent = _tidy(reference), _tidy(disfluent)
        if not reference or not disfluent:
            continue
        if not _usable_reference(reference, for_injection=for_injection):
            continue
        if reference in seen:
            continue
        seen.add(reference)
        kept.append(Utterance(reference=reference, disfluent=disfluent))
        if len(kept) >= limit:
            break
    return kept


def _field(row: dict, name: str, where: str) -> object:
    """Read a column, naming what was actually available when it's missing."""
    if name not in row:
        available = ", ".join(sorted(row)) or "(none)"
        raise RuntimeError(f"field {name!r} not in {where}; available: {available}")
    return row[name]


def hf_token() -> str | None:
    """The Hugging Face token, however the user happens to have supplied it.

    Anonymous requests to the datasets-server are rate limited, so a long run —
    or a few short ones in a row — will start getting 429s. Authenticating lifts
    that.

    `hf auth login` (and the older `huggingface-cli login`) writes a token to a
    file rather than exporting a variable, so checking only the environment would
    ignore the very thing someone reaches for when told to "log in". Resolution
    order matches the `huggingface_hub` library's own, so both routes work and an
    explicit env var still wins.
    """
    for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        token = os.environ.get(name)
        if token and token.strip():
            return token.strip()

    home = os.environ.get("HF_HOME") or os.path.join(os.path.expanduser("~"), ".cache", "huggingface")
    for path in (os.environ.get("HF_TOKEN_PATH"), os.path.join(home, "token")):
        if not path:
            continue
        try:
            token = pathlib.Path(path).read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if token:
            return token
    return None


def _rows_via_api(source: Source, limit: int):
    """Page the datasets-server rows API, yielding raw row dicts."""
    token = hf_token()
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    offset, page = 0, 100
    # Filtering discards a fraction of rows, so allow several pages' worth of
    # headroom before giving up rather than returning a short corpus silently.
    while offset < max(limit * 10, 1000):
        query = urllib.parse.urlencode(
            {
                "dataset": source.dataset,
                "config": source.config or "default",
                "split": source.split,
                "offset": offset,
                "length": page,
            }
        )
        request = urllib.request.Request(f"{ROWS_API}?{query}", headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")[:400]
            if error.code == 429 and not token:
                raise RuntimeError(
                    f"rate limited by {ROWS_API} while reading {source.dataset}, and no Hugging "
                    "Face token was found. Authenticating raises the limit: run `hf auth login`, "
                    "or set HF_TOKEN to a read token from "
                    "https://huggingface.co/settings/tokens"
                ) from error
            raise RuntimeError(
                f"datasets-server returned HTTP {error.code} for {source.dataset}: {body}"
            ) from error
        except urllib.error.URLError as error:
            raise RuntimeError(
                f"could not reach {ROWS_API} ({error.reason}). "
                "Use --loader datasets, or --jsonl / --source builtin to work offline."
            ) from error

        rows = payload.get("rows", [])
        if not rows:
            return
        for entry in rows:
            yield entry.get("row", {})
        offset += page


def _rows_via_datasets(source: Source, _limit: int):
    """Stream the dataset with the `datasets` library, without decoding audio."""
    try:
        import datasets
    except ImportError as error:  # pragma: no cover - depends on the local env
        raise RuntimeError("--loader datasets needs the datasets library: pip install datasets") from error

    stream = datasets.load_dataset(source.dataset, source.config, split=source.split, streaming=True)
    # Audio decoding is pure cost here — the eval never touches the waveform.
    for column, feature in getattr(stream, "features", {}).items():
        if isinstance(feature, datasets.Audio):
            stream = stream.cast_column(column, datasets.Audio(decode=False))
    yield from stream


def _pairs_from_rows(rows, source: Source, where: str):
    """Project raw rows into (disfluent, reference), de-tagging where needed."""
    detag = source.detag or (lambda text: text)
    for row in rows:
        reference = detag(_tidy(_field(row, source.target_field, where)))
        if source.is_paired:
            yield detag(_tidy(_field(row, source.input_field, where))), reference
        else:
            # Reference-only: the injector fills the input side in `load`.
            yield reference, reference


def _pairs_from_jsonl(path: str):
    """Read pairs or bare references from a local file."""
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            if not line.startswith("{"):
                yield line, line
                continue
            row = json.loads(line)
            reference = row.get("reference") or row.get("text") or row.get("transcript") or ""
            yield row.get("disfluent") or reference, reference


def load(
    *,
    source: str = "disfluency-speech",
    loader: str = "datasets-server",
    limit: int = 120,
    split: str | None = None,
    jsonl: str | None = None,
    seed: int = 7,
    severity: float = 0.35,
    strip_formatting: bool = False,
) -> Corpus:
    """Load up to `limit` pairs, injecting disfluencies for reference-only sources."""
    if jsonl:
        pairs = _pairs_from_jsonl(jsonl)
        spec, detail, formatted = None, {"path": jsonl}, True
    elif source == "builtin":
        pairs = ((text, text) for text in BUILTIN_SAMPLE)
        spec, formatted = None, True
        detail = {"note": "bundled sample; no dataset was downloaded"}
    elif source in SOURCES:
        spec = SOURCES[source]
        # Each source defaults to its held-out split, which is small (250 rows for
        # disfluency-speech). A run large enough to separate close candidates has
        # to reach into `train` — harmless here, since nothing is fine-tuned and
        # the harness makes its own train/dev/test partition of whatever it loads.
        if split:
            spec = replace(spec, split=split)
        where = f"{spec.dataset}/{spec.split}"
        rows = (_rows_via_api if loader == "datasets-server" else _rows_via_datasets)(spec, limit)
        pairs = _pairs_from_rows(rows, spec, where)
        formatted = spec.formatting_is_measurable
        detail = {
            "dataset": spec.dataset,
            "config": spec.config,
            "split": spec.split,
            "fields": list(spec.fields),
            "note": spec.note,
        }
    else:
        raise ValueError(f"unknown source {source!r}; expected builtin or one of {', '.join(SOURCES)}")

    # A reference-only source needs the injector to produce an input side, and
    # needs a reference long and well-punctuated enough to inject into. A jsonl
    # file is the user's own text, so it is filtered leniently either way.
    reference_only = spec is None or not spec.is_paired
    utterances = _collect(pairs, limit, for_injection=reference_only and jsonl is None)

    if reference_only:
        injected: list[Utterance] = []
        for index, utterance in enumerate(utterances):
            # A jsonl row that already carried a disfluent side keeps it. Per-example
            # seeds (rather than one shared generator) keep an utterance's
            # disfluencies stable when the corpus around it changes, so re-running
            # with a larger --limit doesn't reshuffle what you already looked at.
            if utterance.is_disfluent:
                injected.append(utterance)
                continue
            disfluent, operations = disfluency.inject(
                utterance.reference,
                seed=seed + index,
                severity=severity,
                strip_formatting=strip_formatting,
            )
            injected.append(
                Utterance(reference=utterance.reference, disfluent=disfluent, operations=operations)
            )
        utterances = injected
        detail |= {"injected": True, "severity": severity, "strip_formatting": strip_formatting}

    if not utterances:
        raise RuntimeError(f"no usable pairs from {source!r} (needs {MIN_WORDS}-{MAX_WORDS} words)")

    return Corpus(
        utterances=tuple(utterances),
        source="jsonl" if jsonl else source,
        detail=detail,
        formatting_is_measurable=formatted,
    )


def split(utterances: list[Utterance], seed: int, dev_fraction: float, test_fraction: float):
    """Shuffle once with a fixed seed, then slice into train / dev / test.

    Shuffling matters because dataset splits are often ordered by speaker or
    source document; slicing an unshuffled corpus would put systematically
    different material in train and test.
    """
    shuffled = list(utterances)
    random.Random(seed).shuffle(shuffled)
    n_test = int(len(shuffled) * test_fraction)
    n_dev = int(len(shuffled) * dev_fraction)
    return shuffled[n_test + n_dev :], shuffled[n_test : n_test + n_dev], shuffled[:n_test]


def no_cleanup_floor(utterances: list[Utterance]) -> dict[str, float]:
    """Score of the corpus's disfluent side against its own target.

    Pure arithmetic — no request is made and no model is involved. It is the floor
    of the *metric*, not of the product: with enhanced transcripts on the service
    always applies some cleanup, so "paste the raw transcript" is not a state Blurt
    can actually be in. Read it as "how much work is there to do on this corpus",
    and treat a candidate scoring below it as actively harmful.
    """
    return metrics.mean([metrics.score(u.reference, u.disfluent) for u in utterances])
