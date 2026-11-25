# Evals

Offline harnesses that decide things about Blurt's behavior before the decision reaches Swift.
This is the repo's only Python, and **none of it ships in the app** — a run's output is a measured
artifact (today: one instruction string) that a human copies into the engine.

| Directory                                           | What it decides                                                                                                                                                                                                                                                      |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`dictation-prompt/`](./dictation-prompt/README.md) | The dictation API's server-side cleanup instruction — `config.llm_instruction`, the string `CleanupInstruction.text` carries. A DSPy/GEPA search over candidate instructions, scored on disfluent-to-clean transcript pairs.                                         |
| [`command-planner/`](./command-planner/README.md)   | Whether the Control Your Mac planner's instruction and schema plan spoken commands right: a corpus of commands over screens, scored on the real planner's plans (Swift, `PlannerEvalTests`), with an importer that drafts cases from the developer-mode command log. |

Each harness documents its own defaults, corpora, and what its numbers can and cannot establish.
Read that README before reading a result: the ceilings here are set by the corpus and by the fact
that we score a stand-in model rather than the service's own rewrite model, and both READMEs say so
where it matters.

## It is gated like shipped code

`scripts/check.sh` runs four checks over this directory, from inside it, and CI runs the same ones:

| Check                 | Scope                              | Fix (in `evals/`)    |
| --------------------- | ---------------------------------- | -------------------- |
| `ruff format --check` | every `.py` here                   | `ruff format`        |
| `ruff check`          | every `.py` here                   | `ruff check --fix`   |
| `mypy`                | every `.py` here, tests included   | fix the types        |
| `pytest` + coverage   | every `test_*.py` in every harness | add the missing test |

The last runs the suites under coverage.py and fails below **100% line and branch coverage** of
the measured code. `program.py`, the DSPy adapter, is left out: DSPy isn't in the dev environment,
so its tests skip there. Code that genuinely can't run under test takes a `# pragma: no cover` with
the reason beside it, never a lowered floor.

All four are platform-independent, so they also run in `scripts/check.sh --portable` — an eval
change can be verified off-Mac, unlike anything touching Swift. A harness whose own correctness is
unchecked is a bad instrument, which is why non-shipping code is gated at all.

How that gate is wired:

- **One [`pyproject.toml`](./pyproject.toml), scoped to this directory**, not the repo root —
  Blurt is a Swift project that happens to contain some Python. It holds the ruff, mypy, pytest and
  coverage.py config and the `dev` dependency group; [`uv.lock`](./uv.lock) pins that group with
  hashes. `uv sync --project evals --locked` (which `scripts/bootstrap.sh`, CI and the web sandbox
  run) creates `evals/.venv`, and `check.sh` prefers its tools over any other copy. Run from
  `evals/`, each tool finds its config with no flags.
- **Every harness directory is covered without being listed.** Each is an import root rather than
  a package — its modules import each other by bare name (`import corpus`) — and the tools run over
  all of them at once, so module names must stay distinct across harnesses; a clash fails loudly.
  Shared test fixtures live in each harness's `conftest.py`.

## Running one

The scripts carry [PEP 723](https://peps.python.org/pep-0723/) headers, so `uv run` installs their
dependencies into a throwaway environment — nothing to set up, no repo-level lockfile or virtualenv:

```bash
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --out results.json
```

The tests and the `--dry-run` paths deliberately import nothing outside the standard library
(`pytest` aside), so they stay runnable with plain `python3` and no API key. A real run costs paid
model calls; each harness's README says how many and what the defaults commit you to.
