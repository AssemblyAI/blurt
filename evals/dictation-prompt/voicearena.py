"""The Voice Arena dictation set's input side: what the service's STT actually wrote.

`VoiceArena/Dictation_Dataset` is the public split (151 clips, CC BY-NC 4.0) of the
benchmark at voicearena.com/dictation-bench, which ranks Blurt among thirteen other
macOS dictation tools. Each clip carries real audio and two references:
`spoken_text`, the words as said, and `intended_text`, what should land on the page.

**Why the input side is not `spoken_text`.** The rewrite this harness tunes never
sees spoken forms. Measured 2026-11-18 on clips from the set: the STT pass already
writes "sixty two thousand" as "$62,000", "plan dot start date" as "plan.startDate"
and "version three" as "version 3". Feeding `spoken_text` to the stand-in would make
the search spend itself on inverse text normalization the production pipeline has
already done, and score candidates on a job the rewrite is never given. So the input
side is the service's own verbatim `text` for the clip, which is exactly what the
rewrite model receives in the product. What remains between that and `intended_text`
is the rewrite's actual job: self-corrections ("over by $7,000. Wait, no, ... $4,000"),
restarts, hedges, and the occasional STT miss.

`--voicearena-input spoken` keeps `spoken_text` instead. It needs no key, which is the
only reason to want it.

**Cost and cache.** One transcription per clip, through the buffered route
(`live.transcribe_encoded`), which decodes the FLAC itself so this needs no Mac. Each
result is written to the cache as it arrives, keyed by clip id and a hash of its
`spoken_text`, so a run interrupted halfway resumes, and a dataset revision that
changes a clip re-transcribes only that clip. Every later run reads the cache and
makes no calls at all.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

DATASET = "VoiceArena/Dictation_Dataset"


def cache_path() -> Path:
    """Where transcripts persist between runs — outside the repo, like any HF cache."""
    root = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(root) / "blurt-evals" / "voicearena-stt.json"


def cache_key(row: dict) -> str:
    """Clip id plus a hash of what was said, so a re-recorded clip is not served stale."""
    digest = hashlib.sha256(str(row.get("spoken_text", "")).encode("utf-8")).hexdigest()
    return f"{row.get('id')}:{digest[:16]}"


def audio_url(row: dict) -> str | None:
    """The clip's audio URL from a datasets-server row, which serves audio as links."""
    audio = row.get("audio")
    if isinstance(audio, list) and audio and isinstance(audio[0], dict):
        return audio[0].get("src")
    return None


def transcripts(rows: list[dict], api_key: str | None, path: Path | None = None) -> dict[str, str]:
    """The service's verbatim transcript for every row, transcribing only what is missing.

    Raises rather than falling back to `spoken_text` when a transcript is missing and
    there is no key: silently scoring a different input side would change what the run
    measures without saying so.
    """
    path = path or cache_path()
    try:
        cached: dict[str, str] = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cached = {}

    missing = [row for row in rows if cache_key(row) not in cached]
    if missing and not api_key:
        raise RuntimeError(
            f"{len(missing)} Voice Arena clip(s) have no cached STT transcript and "
            "ASSEMBLYAI_API_KEY is not set. Set it (one transcription per clip, cached at "
            f"{path}), or pass --voicearena-input spoken to use the dataset's own "
            "spoken_text instead."
        )
    if missing and api_key:
        import urllib.request  # noqa: PLC0415 — only a cache miss touches the network

        import live  # noqa: PLC0415 — stdlib-only, but nothing else here needs it

        print(f"  transcribing {len(missing)} Voice Arena clip(s) once; cached at {path}")
        path.parent.mkdir(parents=True, exist_ok=True)
        for index, row in enumerate(missing, start=1):
            url = audio_url(row)
            if not url:
                raise RuntimeError(f"Voice Arena row {row.get('id')!r} carries no audio URL")
            with urllib.request.urlopen(url, timeout=90) as response:  # noqa: S310
                audio = response.read()
            result = live.transcribe_encoded(audio, api_key, "clip.flac", "audio/flac")
            cached[cache_key(row)] = result.get("text", "")
            # Written per clip, so an interrupted first run resumes where it stopped.
            path.write_text(json.dumps(cached, indent=1) + "\n", encoding="utf-8")
            if index % 25 == 0 or index == len(missing):
                print(f"    {index}/{len(missing)}")

    return {cache_key(row): cached[cache_key(row)] for row in rows}
