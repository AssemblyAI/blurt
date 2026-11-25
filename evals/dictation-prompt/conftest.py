"""Fakes shared by this directory's tests, and the cache redirection every test gets.

The helpers are plain functions; a test module imports them with
`from conftest import ...` (pytest puts this directory on `sys.path`).
"""

from __future__ import annotations

import email.message
import io
import json
import urllib.error
from collections.abc import Callable
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def cache_home(monkeypatch, tmp_path) -> Path:
    """Point every on-disk cache (HF rows, Voice Arena audio and runs) into the test's directory.

    Autouse, so no test can read or write the real `~/.cache`; request it by name for the path.
    """
    home = tmp_path / "cache"
    monkeypatch.setenv("XDG_CACHE_HOME", str(home))
    return home


def http_error(code: int, body: bytes = b"body") -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        "https://x", code, "err", email.message.Message(), io.BytesIO(body)
    )


def config_of(body: bytes) -> dict:
    """The JSON `config` part of a multipart body.

    Found by part name, not by position: this used to take the last `\\r\\n\\r\\n`
    chunk, which silently depended on `config` being the trailing part and broke
    when the streaming route required it to lead.
    """
    part = body.decode("latin-1").split('name="config"')[1]
    return json.loads(part.split("\r\n\r\n")[1].split("\r\n--")[0])


def clip_url(clip_id: str) -> str:
    """The audio URL `va_row` gives a clip."""
    return f"https://example.invalid/{clip_id}.flac"


def va_row(
    clip_id: str,
    spoken: str | None = None,
    intended: str | None = None,
    domain: str | None = None,
    audio: bool = True,
) -> dict:
    """A Voice Arena row in the datasets-server shape."""
    row: dict = {
        "id": clip_id,
        "spoken_text": f"spoken {clip_id}" if spoken is None else spoken,
        "intended_text": f"Intended {clip_id}." if intended is None else intended,
    }
    if domain is not None:
        row["domain"] = domain
    if audio:
        row["audio"] = [{"src": clip_url(clip_id)}]
    return row


def recording_into(seen: list[str]) -> Callable[[str, object], bytes]:
    """A stand-in for `live.recorded` that notes each URL it was asked to fetch."""

    def recorded(url: str, directory: object) -> bytes:
        seen.append(url)
        return b"pcm"

    return recorded
