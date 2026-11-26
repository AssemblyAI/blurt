"""Offline tests for the Voice Arena input side (`voicearena`) and its baseline run.

Nothing here touches the network, a key, `say` or `afconvert`: `urllib.request.urlopen`,
the `live` calls and the third-party `amend` package are all faked, and every cache
lives under `tmp_path` (via `XDG_CACHE_HOME`).
"""

from __future__ import annotations

import csv
import io
import json
import re
import sys
import types

import pytest

import corpus
import live
import voicearena
import voicearena_baseline as vb
from candidates import PRIOR_WINNER, SMART_WINNER
from conftest import clip_url, va_row


def _fake_urlopen(monkeypatch) -> list[str]:
    """Serve every URL as its own bytes; returns the list of URLs fetched."""
    fetched: list[str] = []

    def urlopen(url, timeout=0):
        fetched.append(url)
        return io.BytesIO(url.encode("utf-8"))

    monkeypatch.setattr("urllib.request.urlopen", urlopen)
    return fetched


# --------------------------------------------------------------------------
# voicearena: cache paths, audio, transcripts
# --------------------------------------------------------------------------


def test_cache_path_falls_back_to_home_without_xdg(monkeypatch, tmp_path):
    monkeypatch.delenv("XDG_CACHE_HOME")
    monkeypatch.setenv("HOME", str(tmp_path))
    assert voicearena.cache_path() == tmp_path / ".cache" / "blurt-evals" / "voicearena-stt.json"


def test_a_symlinked_clip_that_resolves_outside_the_cache_is_refused(tmp_path):
    """The final containment check also catches a planted symlink, not just odd ids."""
    row = va_row("dict_0001")
    path = voicearena.audio_path(row)
    path.parent.mkdir(parents=True)
    path.symlink_to(tmp_path / "elsewhere.flac")
    with pytest.raises(ValueError, match="unsafe Voice Arena clip id"):
        voicearena.audio_path(row)


def test_audio_url_reads_only_the_datasets_server_shape():
    assert voicearena.audio_url(va_row("a")) == clip_url("a")
    assert voicearena.audio_url(va_row("a", audio=False)) is None
    assert voicearena.audio_url({"audio": []}) is None
    assert voicearena.audio_url({"audio": ["not a dict"]}) is None
    assert voicearena.audio_url({"audio": {"src": "x"}}) is None


def test_ensure_audio_downloads_only_what_is_missing(monkeypatch, capsys):
    fetched = _fake_urlopen(monkeypatch)
    have, need, no_url = va_row("have"), va_row("need"), va_row("nourl", audio=False)
    voicearena.audio_path(have).parent.mkdir(parents=True)
    voicearena.audio_path(have).write_bytes(b"already")

    voicearena.ensure_audio([have, need, no_url])
    assert fetched == [clip_url("need")]
    assert voicearena.audio_path(need).read_bytes() == clip_url("need").encode()
    assert voicearena.audio_path(have).read_bytes() == b"already"
    assert not voicearena.audio_path(no_url).exists()
    assert "downloading 1 Voice Arena recording(s)" in capsys.readouterr().out

    # Everything is on disk now: a second call makes no requests and says nothing.
    voicearena.ensure_audio([have, need, no_url])
    assert len(fetched) == 1
    assert capsys.readouterr().out == ""


def test_transcripts_resumes_from_a_partial_cache_and_keeps_the_audio(monkeypatch, tmp_path):
    fetched = _fake_urlopen(monkeypatch)
    sent: list[bytes] = []

    def fake_transcribe(audio, api_key, filename, content_type, url=live.BUFFERED_URL):
        sent.append(audio)
        return {"text": f"stt of {audio.decode()}"} if len(sent) == 1 else {}

    monkeypatch.setattr(live, "transcribe_encoded", fake_transcribe)
    rows = [va_row("a"), va_row("b"), va_row("c")]
    path = tmp_path / "nested" / "stt.json"
    path.parent.mkdir()
    path.write_text(json.dumps({voicearena.cache_key(rows[0]): "cached a"}), encoding="utf-8")

    result = voicearena.transcripts(rows, "key", path)
    assert fetched == [clip_url("b"), clip_url("c")]
    assert result == {
        voicearena.cache_key(rows[0]): "cached a",
        voicearena.cache_key(rows[1]): "stt of " + clip_url("b"),
        voicearena.cache_key(rows[2]): "",  # a response with no text is cached as empty
    }
    assert json.loads(path.read_text(encoding="utf-8")) == result
    assert voicearena.audio_path(rows[1]).exists()


def test_a_fully_cached_run_needs_no_key_and_makes_no_calls(monkeypatch, tmp_path):
    monkeypatch.setattr(live, "transcribe_encoded", lambda *a, **k: pytest.fail("no call"))
    row = va_row("a")
    path = tmp_path / "stt.json"
    path.write_text(json.dumps({voicearena.cache_key(row): "cached"}), encoding="utf-8")
    assert voicearena.transcripts([row], None, path) == {voicearena.cache_key(row): "cached"}


def test_transcripts_defaults_to_the_shared_cache_and_reads_a_corrupt_one_as_empty():
    voicearena.cache_path().parent.mkdir(parents=True)
    voicearena.cache_path().write_text("{not json", encoding="utf-8")
    with pytest.raises(RuntimeError, match="1 Voice Arena clip"):
        voicearena.transcripts([va_row("a")], None)


def test_a_missing_clip_without_audio_fails_loudly(monkeypatch, tmp_path):
    monkeypatch.setattr(live, "transcribe_encoded", lambda *a, **k: pytest.fail("no call"))
    with pytest.raises(RuntimeError, match="carries no audio URL"):
        voicearena.transcripts([va_row("x", audio=False)], "key", tmp_path / "stt.json")


def test_progress_is_reported_every_25_clips(monkeypatch, tmp_path, capsys):
    _fake_urlopen(monkeypatch)
    monkeypatch.setattr(live, "transcribe_encoded", lambda *a, **k: {"text": "t"})
    rows = [va_row(f"c{i}") for i in range(26)]
    voicearena.transcripts(rows, "key", tmp_path / "stt.json")
    out = capsys.readouterr().out
    assert "    25/26" in out and "    26/26" in out and "    1/26" not in out


def test_fresh_audio_urls_are_keyed_by_the_tidied_reference(monkeypatch):
    rows = [
        {"intended_text": "  Hello   there. ", "audio": [{"src": "https://x/1.flac"}]},
        {"intended_text": "No audio."},
    ]
    seen = []

    def fake_rows(source, limit):
        seen.append((source.key, limit))
        return iter(rows)

    monkeypatch.setattr(corpus, "_rows_via_api", fake_rows)
    assert voicearena.fresh_audio_urls() == {"Hello there.": "https://x/1.flac"}
    assert seen == [("voicearena", 1000)]


# --------------------------------------------------------------------------
# voicearena_baseline: helpers
# --------------------------------------------------------------------------


def test_summarize_with_nothing_scored_is_zero_not_a_division_error():
    summary = vb.summarize([{"draft_edits": None, "stt_edits": None}])
    assert (summary["scored"], summary["unscored"]) == (0, 1)
    assert summary["draft_zer"] == summary["draft_amend"] == 0.0
    assert summary["stt_zer"] == summary["stt_amend"] == 0.0
    assert not summary["buckets"]


@pytest.mark.parametrize(
    ("stt", "draft", "name"),
    [(0, 0, "pass"), (4, 0, "rewrite fixed it"), (0, 2, "rewrite broke it"), (4, 2, "both fail")],
)
def test_bucket_names_the_stage_that_decided_the_clip(stt, draft, name):
    assert vb.bucket(stt, draft) == name


@pytest.mark.parametrize(
    ("host", "tag"),
    [
        ("dictation.staging.assemblyai.com", "staging"),
        ("localhost:8080", "localhost-8080"),
        ("dictation.eu.assemblyai.com", "eu"),
        ("...", "host"),
    ],
)
def test_host_tag_is_short_filename_safe_and_never_empty(host, tag):
    assert vb._host_tag(host) == tag


def test_write_csv_puts_bucket_last_even_when_the_first_row_has_none(tmp_path):
    out = tmp_path / "t.csv"
    vb.write_csv(str(out), [{"id": "a", "draft": "x"}, {"id": "b", "draft": "y", "bucket": "pass"}])
    with open(out, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert list(rows[0]) == ["id", "draft", "bucket"]
    assert [r["bucket"] for r in rows] == ["", "pass"]

    vb.write_csv(str(out), [])
    assert out.read_text(encoding="utf-8").strip() == "bucket"


def test_save_json_merges_with_what_another_run_wrote(tmp_path):
    path = tmp_path / "deep" / "judge.json"
    vb._save_json(path, {"a": 1})
    vb._save_json(path, {"b": 2})  # a second run that never saw "a"
    assert vb._load_json(path) == {"a": 1, "b": 2}
    assert vb._load_json(tmp_path / "absent.json") == {}


# --------------------------------------------------------------------------
# voicearena_baseline: transcribe_all over faked `live`
# --------------------------------------------------------------------------


def _fake_live(monkeypatch, responses=None) -> list[dict]:
    """Fake the `/live` path; each call's (clip, instruction, url, mode) is recorded.

    `live.recorded` hands back the clip's location as its "PCM", so the response
    can depend on which clip was sent.
    """
    calls: list[dict] = []
    monkeypatch.setattr(live, "require_tools", lambda: None)
    monkeypatch.setattr(live, "recorded", lambda clip, directory: clip.encode("utf-8"))

    def transcribe(pcm, api_key, instruction, url, rewrite_mode=None):
        clip = pcm.decode("utf-8")
        calls.append({"clip": clip, "instruction": instruction, "url": url, "mode": rewrite_mode})
        return (responses or {}).get(clip, {"text": f"stt {clip}"})

    monkeypatch.setattr(live, "transcribe", transcribe)
    return calls


def test_transcribe_all_caches_per_clip_and_reads_the_cache_back(monkeypatch, capsys):
    calls = _fake_live(monkeypatch)
    rows = [va_row("a"), va_row("b")]
    first = vb.transcribe_all(rows, "Clean it.", "smart", "key", workers=2)
    assert [c["mode"] for c in calls] == ["smart", "smart"]
    assert {c["url"] for c in calls} == {"https://dictation.assemblyai.com/v1/transcribe/live"}
    assert first[voicearena.cache_key(rows[0])] == {
        "text": "stt " + clip_url("a"),
        "llm_response": None,
        "llm_error": None,
    }
    cache = vb._cache_dir() / f"voicearena-run-smart-{vb._sha('Clean it.')}.json"
    assert vb._load_json(cache) == first
    assert "Transcribing 2 clip(s) (smart)" in capsys.readouterr().out

    assert vb.transcribe_all(rows, "Clean it.", "smart", "key", workers=2) == first
    assert len(calls) == 2
    assert capsys.readouterr().out == ""


def test_transcribe_all_plays_a_downloaded_clip_from_disk(monkeypatch):
    calls = _fake_live(monkeypatch)
    row = va_row("a")
    voicearena.audio_path(row).parent.mkdir(parents=True)
    voicearena.audio_path(row).write_bytes(b"flac")
    vb.transcribe_all([row], None, "smart", "key", workers=1)
    assert calls[0]["clip"] == str(voicearena.audio_path(row))


def test_fast_mode_host_and_sample_each_get_their_own_cache(monkeypatch):
    calls = _fake_live(monkeypatch)
    vb.transcribe_all([va_row("a")], None, "fast", "key", 1, host="localhost:8080", sample=3)
    assert calls == [
        {
            "clip": clip_url("a"),
            "instruction": None,
            "url": "https://localhost:8080/v1/transcribe/live",
            "mode": None,  # fast is the service default, so no rewrite_mode is sent
        }
    ]
    assert (vb._cache_dir() / "voicearena-run-localhost-8080-fast-default-s3.json").exists()


def test_transcribe_all_refuses_a_clip_with_no_audio(monkeypatch):
    _fake_live(monkeypatch)
    with pytest.raises(ValueError, match="has no audio"):
        vb.transcribe_all([va_row("a", audio=False)], None, "smart", "key", 1)


def test_transcribe_all_reports_progress_every_25(monkeypatch, capsys):
    _fake_live(monkeypatch)
    vb.transcribe_all([va_row(f"c{i}") for i in range(26)], None, "smart", "key", 4)
    out = capsys.readouterr().out
    assert "  25/26" in out and "  26/26" in out and "  1/26" not in out


# --------------------------------------------------------------------------
# voicearena_baseline: the amend judge, faked
# --------------------------------------------------------------------------


class _FakeJudge:
    """Answers each prompt with its intended text, except the ones told to stay silent.

    `silent` maps a draft to how many more times the judge ignores it.
    """

    def __init__(self, workers=0, verbose=False, silent=None):
        self.workers, self.verbose = workers, verbose
        self.silent: dict[str, int] = dict(silent or {})
        self.batches: list[list[str]] = []

    def fix_many(self, prompts, mode):
        assert mode == "sync"
        self.batches.append(list(prompts))
        answers: list[str | None] = []
        for prompt in prompts:
            intended, draft, _ = prompt.split("|")
            if self.silent.get(draft, 0) > 0:
                self.silent[draft] -= 1
                answers.append(None)
            else:
                answers.append(intended)
        return answers


@pytest.fixture
def amend(monkeypatch):
    """A stand-in `amend`: prompt is `intended|draft|spoken`, edits are 0 iff exact."""
    module = types.ModuleType("amend")
    module.__dict__.update(
        Judge=_FakeJudge,
        build_prompt=lambda intended, draft, spoken: f"{intended}|{draft}|{spoken}",
        char_edits=lambda draft, fixed: (0 if draft == fixed else len(fixed), len(fixed)),
    )
    monkeypatch.setitem(sys.modules, "amend", module)
    return module


def test_make_judge_is_amends_judge_unconfigured(amend):
    judge = vb.make_judge(7)
    assert isinstance(judge, _FakeJudge)
    assert (judge.workers, judge.verbose) == (7, True)


def test_judge_all_scores_caches_and_deduplicates_by_prompt(amend, capsys):
    items = [("Good.", "Good.", "s"), ("bad", "Fixed.", "s"), ("Good.", "Good.", "s")]
    judge = _FakeJudge()
    results = vb.judge_all(items, judge)
    assert results == [
        {"fixed": "Good.", "edits": 0, "chars": 5},
        {"fixed": "Fixed.", "edits": 6, "chars": 6},
        {"fixed": "Good.", "edits": 0, "chars": 5},
    ]
    assert len(judge.batches) == 1 and len(judge.batches[0]) == 2
    assert "Judging 2 draft(s)" in capsys.readouterr().out

    # A rerun is served entirely from the cache.
    again = _FakeJudge()
    assert vb.judge_all(items, again) == results
    assert again.batches == []


def test_judge_all_retries_the_unanswered_then_gives_up_after_three(amend, capsys):
    items = [("late", "Late.", "s"), ("never", "Never.", "s"), ("ok", "Ok.", "s")]
    judge = _FakeJudge(silent={"late": 1, "never": 99})
    results = vb.judge_all(items, judge)
    assert [len(b) for b in judge.batches] == [3, 2, 1]
    assert results[0] == {"fixed": "Late.", "edits": 5, "chars": 5}
    assert results[1] is None
    assert results[2] == {"fixed": "Ok.", "edits": 3, "chars": 3}
    out = capsys.readouterr().out
    assert "retrying 2 unanswered (attempt 2/3)" in out
    assert "retrying 1 unanswered (attempt 3/3)" in out


def test_judge_all_stops_retrying_once_everything_is_answered(amend):
    judge = _FakeJudge(silent={"late": 1})
    assert vb.judge_all([("late", "Late.", "s")], judge)[0] is not None
    assert len(judge.batches) == 2


# --------------------------------------------------------------------------
# voicearena_baseline: main, end to end over the fakes
# --------------------------------------------------------------------------


def test_main_needs_both_keys(monkeypatch):
    monkeypatch.delenv("ASSEMBLYAI_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(SystemExit, match="ASSEMBLYAI_API_KEY"):
        vb.main([])
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", "k")
    with pytest.raises(SystemExit, match="ANTHROPIC_API_KEY"):
        vb.main([])


#: Three clips: one the rewrite fixes, one it leaves clean, and one the judge ignores.
_MAIN_ROWS = [
    va_row("fix", domain="code"),
    va_row("clean", domain="medical"),
    va_row("ignored", domain="medical"),
]


@pytest.fixture
def run_main(monkeypatch, amend, capsys):
    """Run `main` against the fakes; returns (exit code, stdout, `live.transcribe` calls)."""
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", "k")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "k")
    monkeypatch.setattr(corpus, "_rows_via_api", lambda source, limit: iter(_MAIN_ROWS))
    calls = _fake_live(
        monkeypatch,
        {
            clip_url("fix"): {"text": "um fix", "llm_response": "Intended fix.", "llm_error": None},
            clip_url("clean"): {"text": "Intended clean.", "llm_response": None, "llm_error": "x"},
            clip_url("ignored"): {"text": "?", "llm_response": "?"},
        },
    )
    # The judge never answers the "ignored" clip, for either the STT text or the draft.
    monkeypatch.setattr(vb, "make_judge", lambda workers: _FakeJudge(silent={"?": 99}))

    def run(argv):
        code = vb.main(argv)
        return code, capsys.readouterr().out, calls

    return run


def test_main_scores_buckets_and_writes_the_table(run_main, tmp_path):
    out_csv = tmp_path / "va.csv"
    code, out, calls = run_main(["--out", str(out_csv)])
    assert code == 0
    assert {c["instruction"] for c in calls} == {SMART_WINNER}
    assert "3 clips" not in out and "2 clips, dictation.assemblyai.com, smart" in out
    assert "shipped instruction" in out
    assert "(1 clip(s) the judge never answered are left out)" in out
    assert "pasted draft" in out and "  100.0" in out
    assert re.search(r"rewrite fixed it +1\n", out) and re.search(r" pass +1\n", out)
    assert re.search(r"code +100\.0  \(1 clips\)", out)
    assert re.search(r"medical +100\.0  \(1 clips\)", out)
    assert f"Wrote {out_csv}" in out

    with open(out_csv, newline="", encoding="utf-8") as handle:
        table = {r["id"]: r for r in csv.DictReader(handle)}
    assert table["fix"]["bucket"] == "rewrite fixed it"
    assert table["fix"]["draft"] == "Intended fix." and table["fix"]["stt_text"] == "um fix"
    # A failed rewrite pastes the verbatim text, and the error is kept.
    assert table["clean"]["draft"] == "Intended clean." and table["clean"]["llm_error"] == "x"
    assert table["clean"]["bucket"] == "pass"
    assert table["ignored"]["bucket"] == "" and table["ignored"]["draft_edits"] == ""


def test_main_with_no_instruction_and_a_limit(run_main):
    code, out, calls = run_main(["--instruction", "none", "--limit", "1", "--rewrite-mode", "fast"])
    assert code == 0
    assert calls == [
        {
            "clip": clip_url("fix"),
            "instruction": None,
            "url": "https://dictation.assemblyai.com/v1/transcribe/live",
            "mode": None,
        }
    ]
    assert "service default (no instruction)" in out
    assert "left out" not in out and "Wrote" not in out


def test_main_uses_the_fast_instruction_in_fast_mode(run_main):
    code, _, calls = run_main(["--rewrite-mode", "fast", "--limit", "1"])
    assert code == 0
    assert [(call["instruction"], call["mode"]) for call in calls] == [(PRIOR_WINNER, None)]


def test_main_sends_an_instruction_file_stripped(run_main, tmp_path):
    instruction = tmp_path / "prompt.txt"
    instruction.write_text("  Tidy it up.\n", encoding="utf-8")
    code, out, calls = run_main(["--instruction-file", str(instruction), "--limit", "1"])
    assert code == 0
    assert calls[0]["instruction"] == "Tidy it up."
    assert "instruction from prompt.txt (11 chars)" in out
