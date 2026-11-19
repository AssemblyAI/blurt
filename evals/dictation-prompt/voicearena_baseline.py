#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["amend-va==0.2.1"]
# ///
"""Score Blurt on the Voice Arena public set the way the leaderboard does, and say why it fails.

The optimizer (`optimize_cleanup_prompt.py`) scores instructions with WER against a
stand-in model. The leaderboard at voicearena.com/dictation-bench scores something
else: ZER, the share of drafts a judge says need **zero** edits, and AMEND, the
pooled share of characters it had to change — both from the `amend-va` package with
Claude Opus 5.5 as the judge. The two disagree on purpose: the judge forgives
rewording, digits versus words and a kept self-correction, all of which WER charges.
So before a multi-hour search, this measures the target itself.

**What it runs.** Every public clip's recording, through the real `/v1/transcribe/live`
route with the shipped instruction (`candidates.PRIOR_WINNER`, byte-identical to
`CleanupInstruction.text`) and `--rewrite-mode` (default `smart`, the mode the
leaderboard ran Blurt in). The draft is what the app would paste: `llm_response`,
falling back to the verbatim `text` when the rewrite failed.

**How it scores.** `amend`'s own prompt (`build_prompt`, version v1) and its own
character metric (`char_edits`) and its own `Judge`, all unchanged — version 0.2.1,
the one the leaderboard was scored with, whose default judge is Claude Opus 5.5 at max
effort through the Anthropic API. The judge is stochastic and our drafts come from
today's service, not the leaderboard's run, so expect a few points of difference from
the published figures rather than a match.

**Why the STT transcript is judged too.** Scoring the verbatim `text` as if it were a
draft separates the two stages. Per clip:

    draft passes                    — nothing to fix
    STT passes, draft fails         — the rewrite broke a clean transcript
    STT fails,  draft passes        — the rewrite fixed it
    both fail                       — read the edits: an STT miss the rewrite can't
                                      undo, or a disfluency the rewrite left in

The last bucket is the one a prompt might still win. Its rows are written to the CSV
with the judge's minimal fix beside each draft, for reading.

**Cost.** 151 transcriptions with the rewrite, and up to 302 judge calls at max effort.
Both are cached under `~/.cache/blurt-evals/`, keyed by what was sent, so a rerun with
the same instruction and mode is free.

    export ASSEMBLYAI_API_KEY=...   # the dictation API
    export ANTHROPIC_API_KEY=...    # the judge
    uv run evals/dictation-prompt/voicearena_baseline.py --out va_baseline.csv

macOS only (`afconvert` turns the FLAC into the PCM `/live` takes).
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sys
import tempfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import corpus  # noqa: E402
import voicearena  # noqa: E402
from candidates import PRIOR_WINNER  # noqa: E402

#: `amend` 0.2.1's defaults, named here only to key the judge cache.
JUDGE_MODEL = "claude-opus-5-5"
JUDGE_EFFORT = "max"

#: Published Blurt figures on the public set (Voice Arena methodology, section 10.6).
PUBLISHED = {"zer": 79.5, "amend": 0.41}

BUCKETS = ("pass", "rewrite broke it", "rewrite fixed it", "both fail")


def bucket(stt_edits: int, draft_edits: int) -> str:
    """Which stage a clip's outcome belongs to — see the module docstring."""
    if draft_edits == 0:
        return "rewrite fixed it" if stt_edits else "pass"
    return "rewrite broke it" if stt_edits == 0 else "both fail"


def summarize(rows: list[dict]) -> dict[str, Any]:
    """ZER (percent) and pooled AMEND (percent) for draft and STT, plus the buckets."""
    scored = [r for r in rows if r["draft_edits"] is not None and r["stt_edits"] is not None]

    def zer(key: str) -> float:
        return 100 * sum(r[key] == 0 for r in scored) / len(scored) if scored else 0.0

    def pooled(edits: str, chars: str) -> float:
        total = sum(r[chars] for r in scored)
        return 100 * sum(r[edits] for r in scored) / total if total else 0.0

    return {
        "scored": len(scored),
        "unscored": len(rows) - len(scored),
        "draft_zer": zer("draft_edits"),
        "draft_amend": pooled("draft_edits", "draft_chars"),
        "stt_zer": zer("stt_edits"),
        "stt_amend": pooled("stt_edits", "stt_chars"),
        "buckets": Counter(bucket(r["stt_edits"], r["draft_edits"]) for r in scored),
    }


def _cache_dir() -> Path:
    return voicearena.cache_path().parent


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _save_json(path: Path, cache: dict) -> None:
    """Merge into what is on disk, then write — two runs share the judge cache.

    Each run holds its own copy in memory, so writing that copy whole would drop
    whatever another run saved in the meantime.
    """
    merged = {**_load_json(path), **cache}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(merged, indent=1) + "\n", encoding="utf-8")


def _load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def transcribe_all(
    rows: list[dict],
    instruction: str | None,
    mode: str,
    api_key: str,
    workers: int,
    host: str = "dictation.assemblyai.com",
):
    """Every clip through `/live` on `host` with this instruction and mode, cached per clip."""
    import live  # noqa: PLC0415 — subprocess + urllib; only this path needs it

    live.require_tools()
    tag = f"{mode}-{_sha(instruction) if instruction else 'default'}"
    if host != "dictation.assemblyai.com":
        tag = f"{host.split('.')[1]}-{tag}"
    path = _cache_dir() / f"voicearena-run-{tag}.json"
    cache = _load_json(path)
    missing = [r for r in rows if voicearena.cache_key(r) not in cache]
    rewrite_mode = None if mode == "fast" else mode

    def one(row: dict) -> tuple[str, dict]:
        with tempfile.TemporaryDirectory(prefix="blurt-va-") as directory:
            pcm = live.recorded(voicearena.local_or_url(row), Path(directory))
        url = f"https://{host}/v1/transcribe/live"
        response = live.transcribe(pcm, api_key, instruction, url, rewrite_mode=rewrite_mode)
        return voicearena.cache_key(row), {
            "text": response.get("text", ""),
            "llm_response": response.get("llm_response"),
            "llm_error": response.get("llm_error"),
        }

    if missing:
        print(f"Transcribing {len(missing)} clip(s) ({mode}); cached at {path}")
        path.parent.mkdir(parents=True, exist_ok=True)
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for done, (key, result) in enumerate(pool.map(one, missing), start=1):
                cache[key] = result
                _save_json(path, cache)
                if done % 25 == 0 or done == len(missing):
                    print(f"  {done}/{len(missing)}")
    return {voicearena.cache_key(r): cache[voicearena.cache_key(r)] for r in rows}


def make_judge(workers: int):
    """`amend`'s own Judge, as shipped: Claude Opus 5.5 at max effort via the Anthropic API.

    Reads `ANTHROPIC_API_KEY`. Nothing is overridden — 0.2.1 is the version the
    leaderboard was scored with, so its defaults are the leaderboard's judge.
    """
    from amend import Judge  # noqa: PLC0415 — third-party; only the run needs it

    return Judge(workers=workers, verbose=True)


def judge_all(items: list[tuple[str, str, str]], judge) -> list[dict | None]:
    """`(draft, intended, spoken)` → amend results, cached by the exact prompt sent."""
    from amend import build_prompt, char_edits  # noqa: PLC0415

    path = _cache_dir() / f"amend-{JUDGE_MODEL}-{JUDGE_EFFORT}.json"
    cache = _load_json(path)
    prompts = [build_prompt(intended, draft, spoken) for draft, intended, spoken in items]
    keys = [_sha(p) for p in prompts]
    todo = sorted({k: p for k, p in zip(keys, prompts, strict=True) if k not in cache}.items())
    if todo:
        print(f"Judging {len(todo)} draft(s) with {JUDGE_MODEL} at {JUDGE_EFFORT} effort")
        for attempt in range(3):
            fixed = judge.fix_many([p for _, p in todo], mode="sync")
            for (key, _), answer in zip(todo, fixed, strict=True):
                if answer is not None:
                    cache[key] = answer
            path.parent.mkdir(parents=True, exist_ok=True)
            _save_json(path, cache)
            todo = [(k, p) for k, p in todo if k not in cache]
            if not todo:
                break
            print(f"  retrying {len(todo)} unanswered (attempt {attempt + 2}/3)")
    results: list[dict | None] = []
    for (draft, _, _), key in zip(items, keys, strict=True):
        if key not in cache:
            results.append(None)
            continue
        edits, chars = char_edits(draft, cache[key])
        results.append({"fixed": cache[key], "edits": edits, "chars": chars})
    return results


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--host",
        default="dictation.assemblyai.com",
        help="dictation host (default: the US one; dictation.eu.assemblyai.com for the EU zone)",
    )
    parser.add_argument(
        "--rewrite-mode",
        default="smart",
        choices=("fast", "smart"),
        help="default: smart, as ranked",
    )
    parser.add_argument(
        "--instruction",
        default="shipped",
        choices=("shipped", "none"),
        help="shipped sends CleanupInstruction.text; none omits it (the service default)",
    )
    parser.add_argument(
        "--instruction-file",
        default=None,
        help="send this file's contents as llm_instruction instead (overrides --instruction)",
    )
    parser.add_argument("--limit", type=int, default=0, help="first N clips only (0: all 151)")
    parser.add_argument(
        "--workers", type=int, default=4, help="parallel transcriptions and judge calls"
    )
    parser.add_argument(
        "--out", default=None, help="write every clip, both judgements and its bucket, as CSV"
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    api_key = os.environ.get("ASSEMBLYAI_API_KEY")
    if not api_key:
        raise SystemExit("ASSEMBLYAI_API_KEY is not set (used for the dictation API)")
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise SystemExit("ANTHROPIC_API_KEY is not set (used by the amend judge)")

    rows = list(corpus._rows_via_api(corpus.SOURCES["voicearena"], 1000))
    if args.limit:
        rows = rows[: args.limit]
    if args.instruction_file:
        instruction = Path(args.instruction_file).read_text(encoding="utf-8").strip()
        label = f"instruction from {Path(args.instruction_file).name} ({len(instruction)} chars)"
    elif args.instruction == "shipped":
        instruction, label = PRIOR_WINNER, "shipped instruction"
    else:
        instruction, label = None, "service default (no instruction)"
    runs = transcribe_all(rows, instruction, args.rewrite_mode, api_key, args.workers, args.host)

    drafts, stts = [], []
    for row in rows:
        run = runs[voicearena.cache_key(row)]
        drafts.append(
            (run["llm_response"] or run["text"], row["intended_text"], row["spoken_text"])
        )
        stts.append((run["text"], row["intended_text"], row["spoken_text"]))
    judge = make_judge(args.workers)
    judged_drafts, judged_stts = judge_all(drafts, judge), judge_all(stts, judge)

    table = []
    for row, draft, stt, jd, js in zip(rows, drafts, stts, judged_drafts, judged_stts, strict=True):
        run = runs[voicearena.cache_key(row)]
        table.append(
            {
                "id": row["id"],
                "domain": row.get("domain", ""),
                "spoken_text": row["spoken_text"],
                "intended_text": row["intended_text"],
                "stt_text": stt[0],
                "draft": draft[0],
                "llm_error": run["llm_error"] or "",
                "stt_fixed": js["fixed"] if js else None,
                "stt_edits": js["edits"] if js else None,
                "stt_chars": js["chars"] if js else None,
                "draft_fixed": jd["fixed"] if jd else None,
                "draft_edits": jd["edits"] if jd else None,
                "draft_chars": jd["chars"] if jd else None,
            }
        )
    for item in table:
        if item["draft_edits"] is not None and item["stt_edits"] is not None:
            item["bucket"] = bucket(item["stt_edits"], item["draft_edits"])

    summary = summarize(table)
    print(
        f"\nVoice Arena public set — {summary['scored']} clips, {args.host}, "
        f"{args.rewrite_mode}, {label}"
    )
    if summary["unscored"]:
        print(f"  ({summary['unscored']} clip(s) the judge never answered are left out)")
    print(f"  {'':<22} {'ZER %':>7} {'AMEND %':>8}")
    print(f"  {'pasted draft':<22} {summary['draft_zer']:>7.1f} {summary['draft_amend']:>8.2f}")
    print(f"  {'STT text, no rewrite':<22} {summary['stt_zer']:>7.1f} {summary['stt_amend']:>8.2f}")
    print(f"  {'published (Blurt)':<22} {PUBLISHED['zer']:>7.1f} {PUBLISHED['amend']:>8.2f}")
    print("\n  Where each clip lands:")
    for name in BUCKETS:
        print(f"    {name:<18} {summary['buckets'].get(name, 0):>4}")
    by_domain: dict[str, list[dict]] = {}
    for item in table:
        if item.get("bucket"):
            by_domain.setdefault(item["domain"], []).append(item)
    print("\n  Draft ZER by domain:")
    for domain, items in sorted(by_domain.items()):
        rate = 100 * sum(i["draft_edits"] == 0 for i in items) / len(items)
        print(f"    {domain:<20} {rate:>6.1f}  ({len(items)} clips)")

    if args.out:
        with open(args.out, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=[*table[0].keys(), "bucket"])
            writer.writeheader()
            writer.writerows(table)
        print(f"\nWrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
