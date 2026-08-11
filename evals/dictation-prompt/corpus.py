"""Reference transcripts, sourced from a Hugging Face speech dataset.

The references are the *ground-truth transcripts* of a spoken-audio corpus —
sentences a person actually said into a microphone, hand-transcribed with real
capitalization and punctuation. That is what makes them the right target for a
dictation-cleanup eval: they are the text a dictation user wanted on screen.

Two loaders, both hitting the same dataset:

- `datasets-server` (default) — the Hugging Face rows API over plain HTTPS. Audio
  columns come back as URLs rather than bytes, so pulling a few hundred
  transcripts costs a few hundred kilobytes and no extra dependency.
- `datasets` (`--source datasets`) — the library, streaming. Use it for gated or
  private datasets where the rows API needs credentials the library already has.

`--jsonl` reads references from a local file instead (one JSON object per line
with a `reference` field, or one raw sentence per line), and `--source builtin`
uses the small bundled sample so the pipeline can be smoke-tested with no network.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

ROWS_API = "https://datasets-server.huggingface.co/rows"

# FLEURS is read speech with expert transcriptions, and its `raw_transcription`
# field keeps the original casing and punctuation (the sibling `transcription`
# field is normalized to lowercase, which would make the formatting axis
# meaningless). Ungated, so the rows API serves it without a token.
DEFAULT_DATASET = "google/fleurs"
DEFAULT_CONFIG = "en_us"
DEFAULT_SPLIT = "test"
DEFAULT_TEXT_FIELD = "raw_transcription"

# Utterance-length window. Below the floor there is not enough text for a
# disfluency to matter; above the ceiling the example stops looking like one
# dictated burst and the scores get dominated by a few long outliers.
MIN_WORDS = 8
MAX_WORDS = 60

# Stand-in corpus for `--source builtin`. Written for this repo (not drawn from
# any dataset) so the offline path carries no third-party licensing.
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
class Corpus:
    """Loaded references plus where they came from, for the results file."""

    references: tuple[str, ...]
    source: str
    detail: dict[str, object]

    def __len__(self) -> int:
        return len(self.references)


def _usable(text: object) -> str | None:
    """Keep well-formed sentences inside the length window; drop everything else."""
    if not isinstance(text, str):
        return None
    cleaned = " ".join(text.split())
    if not cleaned:
        return None
    if not MIN_WORDS <= len(cleaned.split()) <= MAX_WORDS:
        return None
    # A reference with no terminal punctuation is almost always a truncated or
    # normalized transcript; scoring punctuation restoration against it would
    # penalize a correct cleanup.
    if cleaned[-1] not in ".?!":
        return None
    return cleaned


def _collect(candidates, limit: int) -> list[str]:
    """De-duplicate while preserving order, stopping at `limit`."""
    seen: set[str] = set()
    kept: list[str] = []
    for candidate in candidates:
        usable = _usable(candidate)
        if usable is None or usable in seen:
            continue
        seen.add(usable)
        kept.append(usable)
        if len(kept) >= limit:
            break
    return kept


def _load_via_rows_api(
    dataset: str, config: str, split: str, text_field: str, limit: int
) -> list[str]:
    """Page the datasets-server rows API until `limit` usable sentences are found."""
    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    kept: list[str] = []
    seen: set[str] = set()
    offset = 0
    page = 100
    # Filtering discards a good fraction of rows, so allow several pages' worth
    # of headroom before giving up rather than returning a short corpus silently.
    while len(kept) < limit and offset < max(limit * 10, 1000):
        query = urllib.parse.urlencode(
            {
                "dataset": dataset,
                "config": config,
                "split": split,
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
            raise RuntimeError(
                f"datasets-server returned HTTP {error.code} for {dataset}/{config}/{split}: {body}"
            ) from error
        except urllib.error.URLError as error:
            raise RuntimeError(
                f"could not reach {ROWS_API} ({error.reason}). "
                "Use --source datasets, or --jsonl / --source builtin to work offline."
            ) from error

        rows = payload.get("rows", [])
        if not rows:
            break
        for entry in rows:
            row = entry.get("row", {})
            if text_field not in row:
                available = ", ".join(sorted(row)) or "(none)"
                raise RuntimeError(
                    f"field {text_field!r} not in {dataset}/{config}/{split}; available: {available}"
                )
            usable = _usable(row[text_field])
            if usable is None or usable in seen:
                continue
            seen.add(usable)
            kept.append(usable)
            if len(kept) >= limit:
                break
        offset += page

    return kept


def _load_via_datasets(
    dataset: str, config: str, split: str, text_field: str, limit: int
) -> list[str]:
    """Stream the dataset with the `datasets` library, without decoding audio."""
    try:
        import datasets  # noqa: PLC0415 — optional dependency, imported only on this path
    except ImportError as error:  # pragma: no cover - depends on the local env
        raise RuntimeError(
            "--source datasets needs the datasets library: pip install datasets"
        ) from error

    stream = datasets.load_dataset(dataset, config, split=split, streaming=True)
    # Audio decoding is pure cost here — the eval never touches the waveform.
    for column, feature in getattr(stream, "features", {}).items():
        if isinstance(feature, datasets.Audio):
            stream = stream.cast_column(column, datasets.Audio(decode=False))

    def texts():
        for row in stream:
            if text_field not in row:
                available = ", ".join(sorted(row)) or "(none)"
                raise RuntimeError(
                    f"field {text_field!r} not in {dataset}/{config}/{split}; available: {available}"
                )
            yield row[text_field]

    return _collect(texts(), limit)


def _load_jsonl(path: str, limit: int) -> list[str]:
    """Read references from a local file: JSON objects with `reference`, or bare lines."""
    def texts():
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                if line.startswith("{"):
                    row = json.loads(line)
                    yield row.get("reference") or row.get("text") or row.get("transcript")
                else:
                    yield line

    return _collect(texts(), limit)


def load(
    *,
    source: str = "datasets-server",
    dataset: str = DEFAULT_DATASET,
    config: str = DEFAULT_CONFIG,
    split: str = DEFAULT_SPLIT,
    text_field: str = DEFAULT_TEXT_FIELD,
    limit: int = 120,
    jsonl: str | None = None,
) -> Corpus:
    """Load up to `limit` reference transcripts from the requested source."""
    if jsonl:
        return Corpus(
            references=tuple(_load_jsonl(jsonl, limit)),
            source="jsonl",
            detail={"path": jsonl},
        )

    if source == "builtin":
        return Corpus(
            references=tuple(_collect(BUILTIN_SAMPLE, limit)),
            source="builtin",
            detail={"note": "bundled sample; no dataset was downloaded"},
        )

    if source == "datasets-server":
        references = _load_via_rows_api(dataset, config, split, text_field, limit)
    elif source == "datasets":
        references = _load_via_datasets(dataset, config, split, text_field, limit)
    else:
        raise ValueError(f"unknown source {source!r}")

    if not references:
        raise RuntimeError(
            f"no usable transcripts in {dataset}/{config}/{split} field {text_field!r} "
            f"(needs {MIN_WORDS}-{MAX_WORDS} words and terminal punctuation)"
        )

    return Corpus(
        references=tuple(references),
        source=source,
        detail={
            "dataset": dataset,
            "config": config,
            "split": split,
            "text_field": text_field,
        },
    )
