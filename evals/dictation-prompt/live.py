"""Score an instruction on the model that will actually apply it.

Everything else in this harness measures a *stand-in*: `--model` answers the prompt,
and whatever it prefers is what the search optimizes toward. The instruction ships to
AssemblyAI's own rewrite model, which we do not know and cannot select. Beating a
stand-in is not evidence of beating the real thing — the README has said so since the
harness was written, and until now there was nothing to do about it.

There is something to do about it. The dictation API takes audio, so:

    reference text -> `say` -> 16 kHz mono PCM -> POST /transcribe with the
    candidate as config.llm.instruction -> score `llm_response`

The response carries both sides of the question. `text` is the verbatim transcript,
so `score(reference, text)` is the floor — what pasting without any rewrite would
score. `llm_response` is that transcript after the real rewrite model applied the
real instruction, so `score(reference, llm_response)` is the number the product
actually delivers. The gap between them is what the instruction bought.

**What this does and does not establish.** The same audio is used for every candidate,
so the *ranking* is sound. The absolute numbers are not comparable to the text
harness's: synthesized speech is not dictated speech, `say` reads "um" as a word
rather than producing a real hesitation, and the STT pass introduces its own errors
before the rewrite ever runs. Read it as "does this instruction beat that one on the
real rewrite model", which is exactly the question the text harness cannot ask.

macOS only — `say` and `afconvert` are the synthesis path. There is no fallback,
because a silent switch to a different TTS would change what is being measured.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path

import metrics
from corpus import Utterance

#: The dictation endpoint. Same host `AssemblyAITranscriber` posts to.
DICTATION_URL = "https://dictation.assemblyai.com/transcribe"

#: What the service expects, and what `SyncSTTLimits` records on the Swift side.
SAMPLE_RATE = 16_000


class Unavailable(RuntimeError):
    """Synthesis or the endpoint is not usable here — say why, don't half-run."""


def require_tools() -> None:
    """Fail before the first API call if the machine cannot synthesize audio."""
    missing = [tool for tool in ("say", "afconvert") if shutil.which(tool) is None]
    if missing:
        raise Unavailable(
            f"live verification needs {' and '.join(missing)}, which ship with macOS. "
            "Run it on a Mac, or drop --verify-live."
        )


def synthesize(text: str, directory: Path, voice: str | None = None) -> bytes:
    """Speak `text` and return it as raw S16LE PCM — the bytes the API wants.

    Two conversions rather than one: `say` writes AIFF, and `afconvert` retargets it
    to 16 kHz mono little-endian 16-bit. The WAV header is then dropped by slicing
    past it, because the `audio` part is raw PCM with no container — exactly what
    `AssemblyAITranscriber` uploads from the mic.
    """
    aiff, wav = directory / "speech.aiff", directory / "speech.wav"
    say = ["say", "-o", str(aiff)]
    if voice:
        say += ["-v", voice]
    subprocess.run([*say, text], check=True, capture_output=True)
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", str(aiff), str(wav)],
        check=True,
        capture_output=True,
    )
    # 44 bytes is the canonical WAV header afconvert emits for this format.
    return wav.read_bytes()[44:]


def _multipart(pcm: bytes, config: dict) -> tuple[bytes, str]:
    """The `audio` + `config` body, framed exactly as the Swift client frames it."""
    boundary = f"eval-{uuid.uuid4()}"
    body = bytearray()
    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="audio"; filename="audio.pcm"\r\n'
    body += b"Content-Type: audio/pcm\r\n\r\n"
    body += pcm
    body += f"\r\n--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="config"\r\n'
    body += b"Content-Type: application/json\r\n\r\n"
    body += json.dumps(config).encode()
    body += f"\r\n--{boundary}--\r\n".encode()
    return bytes(body), boundary


def transcribe(pcm: bytes, api_key: str, instruction: str | None, url: str = DICTATION_URL) -> dict:
    """One `/transcribe` round trip. `instruction=None` asks for the service default.

    That `None` is the comparison the text harness has never been able to make: an
    empty `llm` block is what Blurt ships today, so it is the real baseline rather
    than `guessed-default`, which only ever guessed at its wording.
    """
    config: dict = {"sample_rate": SAMPLE_RATE, "channels": 1}
    config["llm"] = {"instruction": instruction} if instruction else {}
    body, boundary = _multipart(pcm, config)
    request = urllib.request.Request(  # noqa: S310 — fixed https endpoint
        url,
        data=body,
        headers={
            "Authorization": api_key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:  # noqa: S310
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:300]
        raise Unavailable(f"dictation API returned {error.code}: {detail}") from error


@dataclass(frozen=True)
class LiveResult:
    """One utterance through the real endpoint, both sides of the rewrite scored."""

    reference: str
    verbatim: str
    rewritten: str
    llm_error: str | None

    @property
    def floor(self) -> metrics.Score:
        """What pasting the unrewritten transcript would have scored."""
        return metrics.score(self.reference, self.verbatim)

    @property
    def scored(self) -> metrics.Score:
        """What the instruction actually delivered."""
        return metrics.score(self.reference, self.rewritten)


def verify(
    utterances: list[Utterance],
    instruction: str | None,
    api_key: str,
    *,
    url: str = DICTATION_URL,
    on_example=None,
) -> list[LiveResult]:
    """Run each utterance's *disfluent* side through synthesis and the real endpoint.

    The disfluent side, not the reference: the point is to hand the rewrite model
    something that needs cleaning up. A rewrite that fails (`llm_error`) is recorded
    rather than dropped — the service treats it as best-effort and falls back to the
    verbatim transcript, so that is what the user would have seen, and a run where it
    happens often is a finding rather than an error.
    """
    require_tools()
    results = []
    with tempfile.TemporaryDirectory(prefix="blurt-live-") as directory:
        for utterance in utterances:
            pcm = synthesize(utterance.disfluent, Path(directory))
            response = transcribe(pcm, api_key, instruction, url)
            results.append(
                LiveResult(
                    reference=utterance.reference,
                    verbatim=response.get("text", ""),
                    rewritten=response.get("llm_response") or response.get("text", ""),
                    llm_error=response.get("llm_error"),
                )
            )
            if on_example:
                on_example()
    return results


def summarize(results: list[LiveResult]) -> dict[str, float]:
    """Mean scores plus how often the best-effort rewrite failed outright."""
    if not results:
        return {"floor_content": 0.0, "content": 0.0, "gain": 0.0, "llm_error_rate": 0.0}
    floor = metrics.mean([r.floor for r in results])["content"]
    scored = metrics.mean([r.scored for r in results])["content"]
    return {
        "floor_content": floor,
        "content": scored,
        "gain": scored - floor,
        "llm_error_rate": sum(r.llm_error is not None for r in results) / len(results),
    }
