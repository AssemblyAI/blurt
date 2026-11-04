# /// script
# requires-python = ">=3.11"
# ///
"""Turn Control Your Mac commands from the developer-mode log into draft eval cases.

Reads ``commands.jsonl`` (``DictationLog+Commands.swift``) and writes one draft case per
command in the shape ``cases.json`` takes: what was said, the app and window, and the
numbered elements, rebuilt from the exact user turn the planner was sent. A case's
``expect`` is the plan the model made, as a starting point: a command that "worked" only
ran without an error, so every draft needs a human to confirm or correct the plan before
it joins the corpus. A command the user complained about ("that last command didn't
work") is marked ``reported`` and gets no ``expect`` at all.

    python3 evals/command-planner/import_log.py ~/Library/Logs/Blurt/commands.jsonl
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

_APP = re.compile(r"<frontmost_app>\n(.*?)\n</frontmost_app>", re.S)
_WINDOW = re.compile(r'<window fence="[^"]*"(?: title="(.*?)")?>\n(.*?)</window fence=', re.S)
_ELEMENT = re.compile(r'^\[(\d+)\] (.+?) "(.*)"$')
_SAID = re.compile(r"<spoken_command>\n(.*?)\n</spoken_command>", re.S)
_MORE = "(More is on screen than is listed"


def screen(prompt: str) -> dict:
    """The app, window and elements of a planner user turn, as a case writes them."""
    case: dict = {}
    if app := _APP.search(prompt):
        case["app"] = app.group(1)
    if window := _WINDOW.search(prompt):
        if window.group(1):
            case["window"] = window.group(1)
        elements = []
        for line in window.group(2).splitlines():
            if line.startswith(_MORE):
                case["incomplete"] = True
            elif element := _ELEMENT.match(line):
                elements.append([int(element.group(1)), element.group(2), element.group(3)])
        if elements:
            case["elements"] = elements
    return case


def drafts(lines: list[str]) -> list[dict]:
    """One draft case per logged command, newest last; feedback marks its command."""
    entries = [json.loads(line) for line in lines if line.strip()]
    reported = {entry["about"] for entry in entries if "feedback" in entry and entry.get("about")}
    cases = []
    for entry in entries:
        if "command" not in entry or not entry.get("prompt"):
            continue
        said = _SAID.search(entry["prompt"])
        case = {
            "id": entry["id"],
            "said": said.group(1) if said else entry["command"],
            **screen(entry["prompt"]),
            "logged": {
                "outcome": entry.get("outcome"),
                "promptVersion": entry.get("promptVersion"),
            },
        }
        if entry["id"] in reported:
            case["reported"] = True
        elif entry.get("outcome") in {"done", "pasted", "copied"}:
            case["expect"] = [entry.get("steps", [])]
        cases.append(case)
    return cases


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Draft planner eval cases from commands.jsonl.")
    parser.add_argument("log", type=Path, help="a commands.jsonl from the developer-mode log")
    parser.add_argument("--out", type=Path, help="write the drafts here instead of stdout")
    args = parser.parse_args(argv)
    text = (
        json.dumps(drafts(args.log.read_text().splitlines()), indent=2, ensure_ascii=False) + "\n"
    )
    if args.out:
        args.out.write_text(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
