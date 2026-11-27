"""Offline tests for the live-verification client and the corpus loader's edges.

`test_eval.py` pins the properties the results depend on; this file covers the
paths a run only takes when something is missing or failing — no `say` on the
machine, an HTTP error from the dictation API, a datasets-server that rate-limits
every attempt, a row without the column asked for — plus the injector's rarer
operator outcomes. Nothing here touches the network, runs a subprocess, or needs
an API key: `urlopen`, `subprocess.run`, `shutil.which` and `time.sleep` are all
replaced, and every cache is redirected into `tmp_path`. Run with:

    python3 -m pytest evals/dictation-prompt/test_live_corpus.py
"""

from __future__ import annotations

import io
import shutil
import subprocess
import time
import types
import urllib.error
import urllib.request
import wave
from collections.abc import Callable
from dataclasses import replace

import pytest

import corpus
import disfluency
import live
import metrics
import voicearena
from conftest import clip_url, config_of, http_error, va_row

# --------------------------------------------------------------------------
# Shared fakes
# --------------------------------------------------------------------------

#: The sample frames the fake `afconvert` writes into its WAV.
PCM = b"\x01\x02\x03\x04"


@pytest.fixture
def commands(monkeypatch) -> list[list[str]]:
    """Record every `subprocess.run` command; `afconvert` writes a WAV to its last argument."""
    seen: list[list[str]] = []

    def fake_run(command, check, capture_output):
        assert check and capture_output
        seen.append(command)
        if command[0] == "afconvert":
            with wave.open(command[-1], "wb") as writer:
                writer.setnchannels(1)
                writer.setsampwidth(2)
                writer.setframerate(16000)
                writer.writeframes(PCM)
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(subprocess, "run", fake_run)
    return seen


# --------------------------------------------------------------------------
# live: tools and synthesis
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("absent", "named"),
    [
        ({"say", "afconvert"}, "say and afconvert"),
        ({"afconvert"}, "needs afconvert,"),
        (set(), None),
    ],
)
def test_missing_synthesis_tools_are_named_before_any_api_call(monkeypatch, absent, named):
    monkeypatch.setattr(shutil, "which", lambda tool: None if tool in absent else "/bin/x")
    if named is None:
        live.require_tools()  # all present: passes
        return
    with pytest.raises(live.Unavailable, match=named):
        live.require_tools()


def test_synthesis_speaks_then_retargets_and_drops_the_wav_header(commands, tmp_path):
    assert live.synthesize("ship it", tmp_path, voice="Samantha") == PCM
    say, convert = commands
    assert say == ["say", "-o", str(tmp_path / "speech.aiff"), "-v", "Samantha", "ship it"]
    assert convert[:7] == ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
    assert convert[7:] == [str(tmp_path / "speech.aiff"), str(tmp_path / "speech.wav")]


def test_synthesis_uses_the_system_voice_unless_one_is_named(commands, tmp_path):
    live.synthesize("ship it", tmp_path)
    assert "-v" not in commands[0]


# --------------------------------------------------------------------------
# live: requests
# --------------------------------------------------------------------------


@pytest.fixture
def posted(monkeypatch) -> list[dict]:
    """Replace `_post`, recording what each request would have sent."""
    sent: list[dict] = []

    def fake_post(url, body, boundary, api_key):
        sent.append({"url": url, "body": body, "boundary": boundary, "key": api_key})
        return {"text": "ok"}

    monkeypatch.setattr(live, "_post", fake_post)
    return sent


def test_no_instruction_and_no_mode_sends_only_the_audio_geometry(posted):
    assert live.transcribe(b"pcm", "key", None) == {"text": "ok"}
    [request] = posted
    assert request["url"] == live.DICTATION_URL and request["key"] == "key"
    assert config_of(request["body"]) == {"sample_rate": 16000, "channels": 1}


def test_encoded_audio_goes_to_the_buffered_route_with_an_empty_config(posted):
    live.transcribe_encoded(b"fLaC", "key", "clip.flac", "audio/flac")
    [request] = posted
    assert request["url"] == live.BUFFERED_URL
    text = request["body"].decode("latin-1")
    assert 'filename="clip.flac"' in text and "Content-Type: audio/flac\r\n" in text
    assert config_of(request["body"]) == {}


def test_a_post_carries_the_key_and_boundary_and_decodes_the_reply(monkeypatch):
    seen = []

    def fake_urlopen(request, timeout):
        seen.append((request, timeout))
        return io.BytesIO(b'{"text": "hi", "llm_response": "Hi."}')

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    assert live._post("https://x/live", b"body", "b0", "key") == {
        "text": "hi",
        "llm_response": "Hi.",
    }
    [(request, timeout)] = seen
    assert (request.full_url, request.data, timeout) == ("https://x/live", b"body", 90)
    assert request.get_header("Authorization") == "key"
    assert request.get_header("Content-type") == "multipart/form-data; boundary=b0"


def test_an_http_error_becomes_unavailable_with_a_bounded_detail(monkeypatch):
    def refuse(request, timeout):
        raise http_error(413, b"x" * 1000)

    monkeypatch.setattr(urllib.request, "urlopen", refuse)
    with pytest.raises(live.Unavailable, match="returned 413") as raised:
        live._post("https://x/live", b"", "b0", "key")
    assert str(raised.value).endswith(": " + "x" * 300)


# --------------------------------------------------------------------------
# live: recorded clips
# --------------------------------------------------------------------------


def test_a_clip_on_disk_is_copied_and_converted_without_the_network(commands, tmp_path):
    clip = tmp_path / "kept.flac"
    clip.write_bytes(b"fLaC-local")
    work = tmp_path / "work"
    work.mkdir()
    assert live.recorded(str(clip), work) == PCM
    assert (work / "clip.flac").read_bytes() == b"fLaC-local"
    assert commands[0][-2:] == [str(work / "clip.flac"), str(work / "clip.wav")]


def test_a_clip_url_is_downloaded_then_converted(monkeypatch, commands, tmp_path):
    monkeypatch.setattr(urllib.request, "urlopen", lambda url, timeout: io.BytesIO(b"fLaC-web"))
    assert live.recorded("https://example.invalid/a.flac", tmp_path) == PCM
    assert (tmp_path / "clip.flac").read_bytes() == b"fLaC-web"


def test_a_failed_download_is_unavailable_not_a_crash(monkeypatch, commands, tmp_path):
    def unreachable(url, timeout):
        raise urllib.error.URLError("dns down")

    monkeypatch.setattr(urllib.request, "urlopen", unreachable)
    with pytest.raises(live.Unavailable, match="could not download a recorded clip"):
        live.recorded("http://example.invalid/a.flac", tmp_path)
    assert commands == []


# --------------------------------------------------------------------------
# live: verify
# --------------------------------------------------------------------------


def test_verify_scores_the_rewrite_and_falls_back_to_the_verbatim_text(monkeypatch):
    replies = [
        {"text": "um ship it", "llm_response": "Ship it."},
        {"text": "um ship it", "llm_response": None, "llm_error": "timeout"},
        {},
    ]
    sent = []

    def fake_transcribe(pcm, api_key, instruction, url, rewrite_mode=None):
        sent.append((pcm, api_key, instruction, url, rewrite_mode))
        return replies[len(sent) - 1]

    monkeypatch.setattr(live, "transcribe", fake_transcribe)
    ticks = []
    utterance = corpus.Utterance(reference="Ship it.", disfluent="um ship it")
    results = live.verify(
        [(utterance, b"a"), (utterance, b"b"), (utterance, b"c")],
        "clean it",
        "key",
        url="https://x",
        on_example=lambda: ticks.append(1),
        rewrite_mode="smart",
    )
    assert [(r.verbatim, r.rewritten, r.llm_error) for r in results] == [
        ("um ship it", "Ship it.", None),
        ("um ship it", "um ship it", "timeout"),
        ("", "", None),
    ]
    assert sent[0] == (b"a", "key", "clean it", "https://x", "smart")
    assert len(ticks) == 3
    assert results[0].scored.content == 1.0 > results[0].floor.content
    # The progress callback is optional.
    monkeypatch.setattr(live, "transcribe", lambda *a, **k: {"text": "ship it"})
    [result] = live.verify([(utterance, b"")], None, "key")
    assert result.rewritten == "ship it"


# --------------------------------------------------------------------------
# corpus: small pieces
# --------------------------------------------------------------------------

REFERENCE_ONLY = corpus.Source(key="ref", dataset="d/s", split="train", target_field="text")


def test_a_reference_only_source_names_one_column():
    assert not REFERENCE_ONLY.is_paired
    assert REFERENCE_ONLY.fields == ("text",)
    assert corpus.SOURCES["nyra"].fields == ("verbatim_transcript", "intended_transcript")


def test_the_disfluent_fraction_counts_pairs_that_differ():
    assert corpus.Corpus(utterances=(), source="x", detail={}).disfluent_fraction == 0.0
    pairs = (
        corpus.Utterance(reference="Ship it.", disfluent="um ship it"),
        corpus.Utterance(reference="Ship it.", disfluent="ship it"),
    )
    assert corpus.Corpus(utterances=pairs, source="x", detail={}).disfluent_fraction == 0.5


def test_no_utterances_have_no_false_starts():
    assert corpus.false_start_fraction([]) == 0.0


def test_collect_drops_blank_short_and_repeated_references():
    pairs = [
        ("um", "   "),  # no reference
        ("", "A perfectly usable reference here."),  # no disfluent side
        ("too short", "Too short."),  # under MIN_WORDS
        ("um one two three", "One two three."),
        ("uh one two three", "One two three."),  # already seen
    ]
    kept = corpus._collect(pairs, 10, for_injection=False)
    assert [(u.disfluent, u.reference) for u in kept] == [("um one two three", "One two three.")]


def test_a_missing_column_names_what_was_there():
    with pytest.raises(RuntimeError, match=r"'x' not in ds/s; available: \(none\)"):
        corpus._field({}, "x", "ds/s")
    with pytest.raises(RuntimeError, match="available: a, b$"):
        corpus._field({"b": 1, "a": 2}, "x", "ds/s")


def test_blank_jsonl_lines_are_skipped(tmp_path):
    path = tmp_path / "pairs.jsonl"
    path.write_text('\n  \nShip it now please.\n{"text": "Hello there."}\n', encoding="utf-8")
    assert list(corpus._pairs_from_jsonl(str(path))) == [
        ("Ship it now please.", "Ship it now please."),
        ("Hello there.", "Hello there."),
    ]


# --------------------------------------------------------------------------
# corpus: rows into pairs
# --------------------------------------------------------------------------


def test_a_reference_only_row_yields_its_reference_on_both_sides():
    rows = [{"text": "  Ship   it today. "}]
    assert list(corpus._pairs_from_rows(rows, REFERENCE_ONLY, "d/s")) == [
        ("Ship it today.", "Ship it today.", None)
    ]


def test_an_stt_transcript_replaces_the_rows_input_column():
    row = va_row("dict_0001")
    stt = {voicearena.cache_key(row): "It's room 418, no, 416."}
    [pair] = corpus._pairs_from_rows([row], corpus.SOURCES["voicearena"], "va", stt)
    assert pair == ("It's room 418, no, 416.", "Intended dict_0001.", clip_url("dict_0001"))


def test_stt_input_transcribes_and_keeps_the_audio_at_load(monkeypatch):
    """`--voicearena-input stt` (the default): the service's text, and the clips kept."""
    rows = [
        va_row("dict_0001", intended="It's room 416."),
        va_row("dict_0002", intended="Room 2 it is."),
    ]
    calls: dict[str, object] = {}

    def fake_transcripts(seen_rows, api_key):
        calls["key"] = api_key
        return {voicearena.cache_key(r): f"stt {r['id']}" for r in seen_rows}

    monkeypatch.setenv("ASSEMBLYAI_API_KEY", "aai-key")
    monkeypatch.setattr(corpus, "_rows_via_api", lambda spec, limit: iter(rows))
    monkeypatch.setattr(voicearena, "transcripts", fake_transcripts)
    monkeypatch.setattr(voicearena, "ensure_audio", lambda kept: calls.update(kept=kept))
    loaded = corpus.load(source="voicearena", limit=10)
    assert [u.disfluent for u in loaded.utterances] == ["stt dict_0001", "stt dict_0002"]
    assert calls == {"key": "aai-key", "kept": rows}
    detail = loaded.detail["voicearena"]
    assert isinstance(detail, dict)
    assert detail["input"] == "service STT transcript of the audio"


# --------------------------------------------------------------------------
# corpus: the rows API
# --------------------------------------------------------------------------

UNCACHED = replace(corpus.SOURCES["nyra"], cache_rows=False)


def test_a_token_is_sent_as_a_bearer_header(monkeypatch, cache_home):
    seen = []

    def fake_fetch(url, headers, source, token):
        seen.append((headers, token))
        return {"rows": []}

    monkeypatch.setattr(corpus, "hf_token", lambda: "hf_x")
    monkeypatch.setattr(corpus, "_fetch_page", fake_fetch)
    assert list(corpus._rows_via_api(UNCACHED, 5)) == []
    assert seen == [({"Accept": "application/json", "Authorization": "Bearer hf_x"}, "hf_x")]
    # An uncached source writes nothing, even for an empty page.
    assert not (cache_home / "blurt-evals").exists()


def test_paging_stops_at_the_headroom_even_if_rows_keep_coming(monkeypatch):
    """A filter that discards nearly everything must not page through a whole dataset."""
    offsets = []

    def fake_fetch(url, headers, source, token):
        offsets.append(int(url.split("offset=")[1].split("&")[0]))
        return {"rows": [{"row": {"n": len(offsets)}}, {}]}

    monkeypatch.setattr(corpus, "hf_token", lambda: None)
    monkeypatch.setattr(corpus, "_fetch_page", fake_fetch)
    rows = list(corpus._rows_via_api(UNCACHED, 1))
    # max(1 * 10, 1000) rows of headroom at 100 a page; a row without `row` reads as {}.
    assert offsets == list(range(0, 1000, 100))
    assert rows[:2] == [{"n": 1}, {}] and len(rows) == 20


@pytest.fixture
def always(monkeypatch):
    """Make every fetch fail with a fresh error from `make`; returns the sleeps taken."""
    sleeps: list[float] = []
    monkeypatch.setattr(time, "sleep", sleeps.append)

    def install(make: Callable[[], Exception]) -> list[float]:
        def fail(request, timeout):
            raise make()

        monkeypatch.setattr(urllib.request, "urlopen", fail)
        return sleeps

    return install


@pytest.mark.parametrize(
    ("token", "advice"), [(None, "hf auth login"), ("hf_x", "authenticated ceiling")]
)
def test_a_rate_limit_that_never_lifts_says_what_to_do(always, capsys, token, advice):
    sleeps = always(lambda: http_error(429))
    with pytest.raises(RuntimeError, match=f"still after 5 attempts.*{advice}"):
        corpus._fetch_page("https://x", {}, corpus.SOURCES["nyra"], token)
    assert sleeps == [4.0, 8.0, 16.0, 32.0]
    assert "rate limited; retrying in 4s (1/5)" in capsys.readouterr().out


def test_a_gateway_error_that_never_clears_fails_after_every_attempt(always, capsys):
    sleeps = always(lambda: http_error(503, b"upstream down"))
    with pytest.raises(RuntimeError, match="HTTP 503 .* on all 5 attempts: upstream down"):
        corpus._fetch_page("https://x", {}, corpus.SOURCES["nyra"], None)
    assert len(sleeps) == 4
    assert "datasets-server HTTP 503; retrying" in capsys.readouterr().out


def test_an_unreachable_server_points_at_the_offline_sources(always):
    sleeps = always(lambda: urllib.error.URLError("dns down"))
    with pytest.raises(RuntimeError, match=r"could not reach .* \(dns down\)\. Use --jsonl"):
        corpus._fetch_page("https://x", {}, corpus.SOURCES["nyra"], None)
    assert sleeps == []


# --------------------------------------------------------------------------
# disfluency: operators that have nothing to work with
# --------------------------------------------------------------------------


class _ScriptedRandom:
    """Stands in for `random.Random`: fires an event on the scripted draws, never otherwise."""

    def __init__(self, draws: list[float], operations: list[str]):
        self._draws, self._operations = draws, operations

    def random(self) -> float:
        return self._draws.pop(0) if self._draws else 0.99

    def choices(self, population, weights):
        return [self._operations.pop(0)]

    def choice(self, sequence):
        return sequence[0]

    def randint(self, low: int, high: int) -> int:
        return low


def _scripted(monkeypatch, draws: list[float], operations: tuple[str, ...] = ()) -> None:
    rng = _ScriptedRandom(draws, list(operations))
    monkeypatch.setattr(disfluency, "random", types.SimpleNamespace(Random=lambda seed: rng))


def test_an_empty_reference_is_returned_untouched():
    assert disfluency.inject("", seed=1) == ("", ())
    assert disfluency.inject("   ", seed=1, severity=1.0) == ("   ", ())


def test_an_opener_keeps_a_proper_nouns_capital(monkeypatch):
    _scripted(monkeypatch, [0.0])  # the opener fires; no token event does
    assert disfluency.inject("NASA launched it.", seed=1, severity=1.0) == (
        "so NASA launched it.",
        ("opener",),
    )


@pytest.mark.parametrize(
    ("reference", "operation"),
    [
        ("— fine then.", "repeat"),  # a bare dash has no word to repeat
        ("Go to it now.", "false_start"),  # no word long enough to borrow
        ("Ship it now.", "restart"),  # nothing said yet to restart from
    ],
)
def test_an_operator_with_nothing_to_work_with_is_skipped(monkeypatch, reference, operation):
    # The opener draw misses, then the first token's event fires.
    _scripted(monkeypatch, [0.99, 0.0], (operation,))
    assert disfluency.inject(reference, seed=1, severity=1.0) == (reference, ())


# --------------------------------------------------------------------------
# metrics: edges
# --------------------------------------------------------------------------


def test_an_empty_reference_is_wrong_only_if_words_were_added():
    assert metrics.align([], []).error_rate == 0.0
    assert metrics.align([], ["um"]).error_rate == 1.0


def test_feedback_on_right_words_in_the_wrong_format_says_so():
    scored = metrics.score("Ship it today.", "ship it today", "ship it today")
    note = metrics.feedback("Ship it today.", "ship it today", scored, axis="blend")
    assert "wording is correct but capitalization or punctuation differs" in note
