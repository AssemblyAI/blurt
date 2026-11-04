# Command planner eval

How well the Control Your Mac planner (`VoiceCommandPlanner`) turns a spoken command into steps.
Each case in [`cases.json`](./cases.json) is something said over a screen: the app, the window,
and the numbered elements the screen read listed. A case is scored on the plan the real planner
makes of it. That means the same instruction, schema, retry and parser that ship
(`VoiceCommandStep.steps(fromReply:maxSteps:listed:)`), with no Python port that could drift.

The harness is Swift, in `Tests/BlurtEngineTests/PlannerEvalTests.swift`:

| Part                           | Runs                   | Checks                                                                                                  |
| ------------------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------- |
| corpus + scoring               | every `swift test`     | Unique ids; each element a plan names is listed; refusal cases exist; the matcher itself                |
| live planner                   | `BLURT_PLANNER_EVAL=1` | The pass rate across every case, run `BLURT_PLANNER_EVAL_RUNS` times (3 by default), clears `passFloor` |
| log importer (`import_log.py`) | `check.sh` (pytest)    | Reads back exactly the user turn the planner sends                                                      |

```bash
BLURT_PLANNER_EVAL=1 ASSEMBLYAI_API_KEY=… BLURT_PLANNER_EVAL_OUT=/tmp/planner-eval.json \
  swift test --filter PlannerEvalTests/live
```

A run costs one or two gateway calls per case per run: 25 cases × 3 runs is about 75–90
completions. It prints `PASSED=n/total`, the model, and `promptVersion`, followed by every failing
plan. The JSON written to `BLURT_PLANNER_EVAL_OUT` has a verdict for each case.

## Recorded screens

A written case lists the handful of elements it needs. A real window lists up to 150, in the app's
own order, with its clutter. Two kinds of case use real windows, recorded from real apps
(`Tests/ScreenTrees`, every string swapped for fake text — see AGENTS.md):

- **Written over a recording.** A case with `"screen": "Slack"` instead of `app` and `elements` is
  planned over that recording's listing, made by the screen read's own code (`ScreenRead`). Name a
  target by its label in a pattern, `press #* (* "Unreads")`, since its number is the recording's.
- **Generated from every recording** (`PlannerEval+Screens.swift`). For each recording: a click on
  every generic interface word it lists once ("Click Activity"), a click on three elements picked by
  their fake names ("Click on Lorem 47", seeded by the recording's name, so the same every run), and a
  search when it lists a search field. 65 cases from the eight recordings.

`BLURT_PLANNER_EVAL_SET` picks what runs: `corpus` (this directory's `cases.json`), `screens` (the
generated cases), or `all`, the default. A run of all is about 140 cases × 3 runs.

## Reading a result

- **One run is noise.** The gateway's model doesn't give the same answer twice, even at
  temperature 0. On the same prompt, single runs of 25 ranged over 20–22. Compare pass rates at 3
  runs or more, and compare like with like by `promptVersion`.
- **A timeout counts as a failure.** A gateway request that runs past the planner's 30 s timeout
  fails the case, as it would fail the command. A run with several timeouts is measuring the
  gateway, not the prompt.
- **A pass means the plan, not the outcome.** Nothing is performed. A case passes when the plan
  matches one of the accepted plans and does nothing listed in its `forbid`. Whether the steps then
  work in the app is the real performer's job. That isn't tested here.

## Writing a case

```json
{
  "id": "press-listed",
  "said": "Click reply.",
  "app": "Mail",
  "window": "Inbox",
  "incomplete": false,
  "elements": [[2, "button", "Reply"]],
  "expect": [["press #2*"], ["press_button \"Reply\""]],
  "forbid": ["open_app Terminal"]
}
```

- **`expect` lists the accepted plans.** Each plan is a list of steps, each written as the command
  log writes it (`VoiceCommandStep.logLine`). Steps are matched case-insensitively, with `*` for any
  run of characters. An empty plan, `[]`, accepts a refusal: the planner answering that it can't
  or won't (`notUnderstood`, `refused`).
- **List every plan that would really work, not the one you'd write.** Music's next track is
  `media next_track` _or_ `shortcut cmd+right`. Where a single plan is all that's right, keep only
  that one: `window maximize` for "fill the screen", not `full_screen`.
- **Check a case against the instruction before blaming the model.** A Volume slider in Music was
  a bad case, because the instruction makes the system volume a media key.

## Growing the corpus from real use

With developer mode on, every command lands in `commands.jsonl` with the exact prompt the planner
saw. To draft cases from it:

```bash
python3 evals/command-planner/import_log.py ~/Library/Logs/Blurt/commands.jsonl --out drafts.json
```

The importer rebuilds each command's screen from that prompt and drafts the case from it:

- A command that ran gets the model's plan as its `expect`. That's only a starting point: "done"
  means no step threw an error, not that the plan was right.
- A command you complained about ("that last command didn't work") is marked `reported` and gets
  no `expect`. Write the right plan yourself.

Drafts carry `logged` and `reported` keys that the corpus doesn't take, so a draft can't be pasted
into `cases.json` unreviewed without the corpus test failing.
