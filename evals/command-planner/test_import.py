"""Offline tests for the planner eval's log importer and its corpus file.

No network, no API key: the importer must read back exactly the user turn
``VoiceCommandPlanner.prompt`` writes, and the corpus must stay in the shape
``PlannerEvalTests`` decodes. Run with:

    python3 -m pytest evals/command-planner/test_import.py
"""

from __future__ import annotations

import json
import pathlib

import import_log

HERE = pathlib.Path(__file__).parent

# As `ScreenContext.promptText(fence:)` and `VoiceCommandPlanner.prompt` write it.
PROMPT = (
    "<frontmost_app>\nMail\n</frontmost_app>\n\n"
    '<window fence="ab12cd34" title="Inbox">\n'
    '[4] button "Reply"\n'
    '[7] row "Lunch on Friday? ‹b›"\n'
    "(More is on screen than is listed: an element not listed may still be there.)\n"
    '</window fence="ab12cd34">\n\n'
    "<spoken_command>\nreply to lunch\n</spoken_command>"
)


def entry(**fields) -> str:
    base = {
        "id": "c1",
        "command": "reply to lunch",
        "prompt": PROMPT,
        "steps": ['press #4 (button "Reply")'],
        "outcome": "done",
        "promptVersion": "v1",
    }
    return json.dumps(base | fields)


def test_screen_reads_back_app_window_and_elements():
    assert import_log.screen(PROMPT) == {
        "app": "Mail",
        "window": "Inbox",
        "incomplete": True,
        "elements": [[4, "button", "Reply"], [7, "row", "Lunch on Friday? ‹b›"]],
    }


def test_screen_with_only_an_app():
    assert import_log.screen("<frontmost_app>\nFinder\n</frontmost_app>") == {"app": "Finder"}


def test_a_command_that_ran_drafts_its_plan_as_the_expectation():
    [case] = import_log.drafts([entry()])
    assert case["said"] == "reply to lunch"
    assert case["expect"] == [['press #4 (button "Reply")']]
    assert case["logged"] == {"outcome": "done", "promptVersion": "v1"}


def test_a_reported_or_failed_command_gets_no_expectation():
    complaint = json.dumps({"feedback": "that didn't work", "about": "c1"})
    [reported, failed] = import_log.drafts([entry(), complaint, entry(id="c2", outcome="failed")])
    assert reported["reported"] is True and "expect" not in reported
    assert "expect" not in failed and "reported" not in failed


def test_entries_without_a_prompt_are_skipped():
    assert import_log.drafts([entry(prompt=None), "", json.dumps({"feedback": "x"})]) == []


def test_the_corpus_is_in_the_shape_the_swift_eval_decodes():
    corpus = json.loads((HERE / "cases.json").read_text())
    assert 0.5 <= corpus["passFloor"] <= 1
    # Which keys a case may carry is the Swift decoder's to say
    # (PlannerEvalTests.corpusIsAnonymous reads them off Case.CodingKeys).
    recordings = {
        path.stem for path in (HERE.parent.parent / "Tests" / "ScreenTrees").glob("*.json")
    }
    for case in corpus["cases"]:
        assert {"id", "said", "expect"} <= set(case), case["id"]
        # Over a recorded screen (Tests/ScreenTrees), or one written in the case.
        assert ("screen" in case) != ("app" in case), case["id"]
        if "screen" in case:
            assert case["screen"] in recordings, case["id"]
        for element in case.get("elements", []):
            assert isinstance(element[0], int) and len(element) == 3, case["id"]
