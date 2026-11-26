"""Score an instruction on the model that will actually apply it.

Everything else in this harness measures a *stand-in*: `--model` answers the prompt,
and whatever it prefers is what the search optimizes toward. The instruction ships to
AssemblyAI's own rewrite model, which we do not know and cannot select. Beating a
stand-in is not evidence of beating the real thing — the README has said so since the
harness was written, and until now there was nothing to do about it.

There is something to do about it. The dictation API takes audio, so:

    reference text -> `say` -> 16 kHz mono PCM -> POST /transcribe with the
    candidate as config.llm_instruction -> score `llm_response`

The response carries both sides of the question. `text` is the verbatim transcript,
so `score(reference, text)` is the floor — what pasting without any rewrite would
score. `llm_response` is that transcript after the real rewrite model applied the
real instruction, so `score(reference, llm_response)` is the number the product
actually delivers. The gap between them is what the instruction bought.

The verbatim transcript is also what the false-start surcharge is measured against here
(`metrics.FALSE_START_WEIGHT`), since it is what the rewrite model was handed. It is a
noisier input than a corpus row: `say` produces no cut-off words at all, so the abandoned
spans the classifier finds are whatever the STT pass and the annotation-free heuristic
agree on. Same transcript for every candidate, so the comparison holds; the absolute
figure carries even less meaning here than the rest of this file's do.

**What this does and does not establish.** The same audio is used for every candidate,
so the *ranking* is sound. The absolute numbers are not comparable to the text
harness's: synthesized speech is not dictated speech, `say` reads "um" as a word
rather than producing a real hesitation, and the STT pass introduces its own errors
before the rewrite ever runs. Read it as "does this instruction beat that one on the
real rewrite model", which is exactly the question the text harness cannot ask.

**Recorded audio, where a corpus has it.** Voice Arena rows carry a recording of a real
person dictating, and those are played as recorded (`recorded`) rather than spoken by
`say` — the caveats above about synthesized speech do not apply to them.

macOS only — `say` and `afconvert` are the synthesis and conversion path. There is no
fallback, because a silent switch to a different TTS would change what is being measured.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
import uuid
import wave
from dataclasses import dataclass, replace
from pathlib import Path

import metrics
from corpus import Utterance

#: The dictation endpoint. Same host `AssemblyAITranscriber` posts to.
DICTATION_URL = "https://dictation.assemblyai.com/v1/transcribe/live"

#: What the service expects, and what `RecordingLimits` records on the Swift side.
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
    return _pcm(wav)


def _multipart(
    audio: bytes, config: dict, filename: str = "audio.pcm", content_type: str = "audio/pcm"
) -> tuple[bytes, str]:
    """The `config` + `audio` body, framed exactly as the Swift client frames it.

    `config` leads, because the streaming route cannot open its upstream call
    without it and answers an audio-first body with a 400. The Swift client
    (`AssemblyAITranscriber.configHead` / `audioPartHeader`) writes these same
    bytes in this same order; this harness tunes the instruction that rides in
    the `config` part, so a body shaped differently from the app's would be
    tuning against a different request.

    `filename` and `content_type` exist for `transcribe_encoded`, which sends a FLAC
    file to the buffered route; the live route only decodes raw PCM incrementally.
    """
    boundary = f"eval-{uuid.uuid4()}"
    body = bytearray()
    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="config"\r\n'
    body += b"Content-Type: application/json\r\n\r\n"
    body += json.dumps(config).encode()
    body += f"\r\n--{boundary}\r\n".encode()
    body += f'Content-Disposition: form-data; name="audio"; filename="{filename}"\r\n'.encode()
    body += f"Content-Type: {content_type}\r\n\r\n".encode()
    body += audio
    body += f"\r\n--{boundary}--\r\n".encode()
    return bytes(body), boundary


def transcribe(
    pcm: bytes,
    api_key: str,
    instruction: str | None,
    url: str = DICTATION_URL,
    rewrite_mode: str | None = None,
) -> dict:
    """One `/v1/transcribe/live` round trip. `instruction=None` asks for the default.

    That `None` is the comparison the text harness has never been able to make:
    omitting the instruction selects the service's own default wording — the route
    rewrites by default — so it is the real baseline rather than `guessed-default`,
    which only ever guessed at it.

    Field name and shape track the Swift client exactly (`config.llm_instruction`,
    a top-level string). It sent the nested `config.llm.instruction` until
    2026-09-10; both are accepted by the route, but a harness tuning a field the
    app does not send is tuning the wrong request.

    `rewrite_mode` mirrors the app's Fast/Smart setting: None omits the key (Fast, the
    default) and `"smart"` asks for the larger rewrite model, exactly as
    `RewriteMode.wireValue` does on the Swift side.
    """
    config: dict = {"sample_rate": SAMPLE_RATE, "channels": 1}
    if instruction:
        config["llm_instruction"] = instruction
    if rewrite_mode:
        config["rewrite_mode"] = rewrite_mode
    body, boundary = _multipart(pcm, config)
    return _post(url, body, boundary, api_key)


#: The buffered route. Unlike `/live` it decodes encoded audio (FLAC, WAV) itself.
BUFFERED_URL = "https://dictation.assemblyai.com/v1/transcribe"


def transcribe_encoded(
    audio: bytes, api_key: str, filename: str, content_type: str, url: str = BUFFERED_URL
) -> dict:
    """Transcribe an encoded file through the buffered route, no instruction sent.

    For building a corpus's input side from recorded audio (`voicearena.py`), where
    only the verbatim `text` is wanted. The buffered route decodes the file itself, so
    this path needs no `afconvert` and runs off-Mac. Measured 2026-11-18: a FLAC sent
    to `/live` is refused with 415 ("cannot be decoded incrementally"), and the same
    file sent here comes back transcribed.
    """
    body, boundary = _multipart(audio, {}, filename=filename, content_type=content_type)
    return _post(url, body, boundary, api_key)


def _post(url: str, body: bytes, boundary: str, api_key: str) -> dict:
    """POST a multipart body, turning an HTTP error into `Unavailable` with its detail."""
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
        return metrics.score(self.reference, self.verbatim, self.verbatim)

    @property
    def scored(self) -> metrics.Score:
        """What the instruction actually delivered."""
        return metrics.score(self.reference, self.rewritten, self.verbatim)


def recorded(url: str, directory: Path) -> bytes:
    """Download a recorded clip and convert it to the raw PCM `/live` takes.

    For corpora that ship real audio (`voicearena`). `afconvert` reads the FLAC and
    resamples it to 16 kHz mono, the same retargeting `synthesize` applies to `say`.
    """
    encoded, wav = directory / "clip.flac", directory / "clip.wav"
    if not url.startswith(("http://", "https://")):
        # A path: the clip was kept on disk at load (`voicearena.ensure_audio`).
        encoded.write_bytes(Path(url).read_bytes())
    else:
        try:
            with urllib.request.urlopen(url, timeout=90) as response:  # noqa: S310 — dataset asset
                encoded.write_bytes(response.read())
        except urllib.error.URLError as error:
            raise Unavailable(f"could not download a recorded clip ({error})") from error
    subprocess.run(
        [
            "afconvert",
            "-f",
            "WAVE",
            "-d",
            f"LEI16@{SAMPLE_RATE}",
            "-c",
            "1",
            str(encoded),
            str(wav),
        ],
        check=True,
        capture_output=True,
    )
    return _pcm(wav)


def _pcm(wav: Path) -> bytes:
    """A WAV file's sample frames, without its header (whatever chunks that holds)."""
    with wave.open(str(wav), "rb") as reader:
        return reader.readframes(reader.getnframes())


def synthesize_all(utterances: list[Utterance]) -> list[tuple[Utterance, bytes]]:
    """Audio for every utterance, prepared once: the recording if it has one, else `say`.

    A recording is the speaker's own voice saying the disfluent side, which is what
    the product actually hears; `say` stands in only where a corpus has no audio. With
    it, the "synthesized speech is not dictated speech" caveat no longer applies.

    Separate from `verify` so a caller comparing several instructions prepares once
    and replays the same bytes. That halves the subprocess and download work of a
    `--verify-baseline` run, and it is what makes "the same audio for every candidate"
    structurally true rather than true because `say` happens to be deterministic.
    """
    require_tools()
    # Recordings are normally on disk by now (`voicearena.ensure_audio`). A clip that
    # still points at a URL has a signed one, expiring within hours of the corpus
    # load — and a search runs for hours: one run's every download came back 403. So
    # re-read those, fresh, matched by reference; if the server is down too, keep the
    # old URL and let the download say so rather than fail the whole check here.
    if any(u.audio_url and u.audio_url.startswith("http") for u in utterances):
        import voicearena  # noqa: PLC0415 — deferred: it imports corpus, which imports this

        try:
            fresh = voicearena.fresh_audio_urls()
        except RuntimeError as error:
            print(f"  could not refresh recording URLs ({error}); using the ones from load")
            fresh = {}
        utterances = [
            replace(u, audio_url=fresh.get(u.reference, u.audio_url))
            if u.audio_url and u.audio_url.startswith("http")
            else u
            for u in utterances
        ]
    with tempfile.TemporaryDirectory(prefix="blurt-live-") as directory:
        return [
            (
                u,
                recorded(u.audio_url, Path(directory))
                if u.audio_url
                else synthesize(u.disfluent, Path(directory)),
            )
            for u in utterances
        ]


def verify(
    spoken: list[tuple[Utterance, bytes]],
    instruction: str | None,
    api_key: str,
    *,
    url: str = DICTATION_URL,
    on_example=None,
    rewrite_mode: str | None = None,
) -> list[LiveResult]:
    """Send already-synthesized audio through the real endpoint and score the rewrite.

    A rewrite that fails (`llm_error`) is recorded rather than dropped — the service
    treats it as best-effort and falls back to the verbatim transcript, so that is what
    the user would have seen, and a run where it happens often is a finding rather than
    an error.
    """
    results = []
    for utterance, pcm in spoken:
        response = transcribe(pcm, api_key, instruction, url, rewrite_mode=rewrite_mode)
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
    floor = metrics.mean([r.floor for r in results])["content"]
    scored = metrics.mean([r.scored for r in results])["content"]
    return {
        "floor_content": floor,
        "content": scored,
        "gain": scored - floor,
        "llm_error_rate": (
            sum(r.llm_error is not None for r in results) / len(results) if results else 0.0
        ),
    }
