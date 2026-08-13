# Evals

Offline harnesses that decide things about Blurt's behavior before the decision reaches Swift.
This is the repo's only Python, and **none of it ships in the app** — a run's output is a measured
artifact (today: one instruction string) that a human copies into the engine.

| Directory                                           | What it decides                                                                                                                                                                                                              |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`dictation-prompt/`](./dictation-prompt/README.md) | The dictation API's server-side cleanup instruction — `config.llm.instruction`, the string `CleanupInstruction.text` carries. A DSPy/GEPA search over candidate instructions, scored on disfluent-to-clean transcript pairs. |

Each harness documents its own defaults, corpora, and what its numbers can and cannot establish.
Read that README before reading a result: the ceilings here are set by the corpus and by the fact
that we score a stand-in model rather than the service's own rewrite model, and both READMEs say so
where it matters.

## It is gated like shipped code

`scripts/check.sh` runs three checks over this directory, and CI runs the same ones:

| Check                 | Scope                                 | Fix                       |
| --------------------- | ------------------------------------- | ------------------------- |
| `ruff format --check` | `evals/`                              | `ruff format evals/`      |
| `ruff check`          | `evals/`                              | `ruff check --fix evals/` |
| `pytest -q`           | `evals/dictation-prompt/test_eval.py` | fix the test or the code  |

All three are platform-independent, so they also run in `scripts/check.sh --portable` — an eval
change can be verified off-Mac, unlike anything touching Swift. A harness whose own correctness is
unchecked is a bad instrument, which is why non-shipping code is gated at all.

Two things follow from how that gate is wired:

- **`ruff.toml` is scoped to this directory**, not the repo root — Blurt is a Swift project that
  happens to contain some Python. Ruff finds it by walking up from each file, so `ruff check evals/`
  from the repo root picks it up. The config comments explain the line width and the `src` setting.
- **The pytest step names one file.** A second harness's tests are not picked up by wildcard; add
  them to the `pytest` invocation in `scripts/check.sh` in the same commit that adds them, or they
  are decoration.

## Running one

The scripts carry [PEP 723](https://peps.python.org/pep-0723/) headers, so `uv run` installs their
dependencies into a throwaway environment — nothing to set up, no repo-level lockfile or virtualenv:

```bash
uv run evals/dictation-prompt/optimize_cleanup_prompt.py --out results.json
```

The tests and the `--dry-run` paths deliberately import nothing outside the standard library
(`pytest` aside), so they stay runnable with plain `python3` and no API key. A real run costs paid
model calls; each harness's README says how many and what the defaults commit you to.
