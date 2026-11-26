---
name: check
description: Verify the repo is green by running scripts/check.sh — the same full health check CI runs (swift test + coverage gate, sanitizers, xcodegen drift, app build, swift-format/swiftlint/periphery/prettier/markdownlint/shellcheck/shfmt, settled-decision invariants, ruff + mypy + pytest with a 95% coverage gate over evals/). Its read-only checks report together, so a red run names every failure at the bottom rather than stopping at the first. Use before claiming a change builds, passes, or is ready to commit/PR. Bakes in the macOS-only guard so a Linux/web sandbox flags "verify on a Mac" instead of fabricating a green result; there, scripts/check.sh --portable runs the platform-independent subset — run it before every push, Swift changes included. On a Mac, scripts/check.sh --lint-only runs just the read-only checks in minutes.
---

# check — is this green?

`scripts/check.sh` is the **single source of truth** for "is this green?" It is
exactly what CI (`.github/workflows/check.yml`, `macos-26`) runs, so a clean
local `check.sh` matches CI by construction.

## Before you run: the macOS-only guard

Blurt is macOS-only (`platforms: [.macOS(.v15)]`, AppKit + AVFoundation). The
engine imports AVFoundation, so even the SPM package won't compile off-Mac.

**If `xcodebuild`/`xcodegen` are unavailable (Linux or web sandbox — a Linux
`swift` may well be present, but it has no Apple SDK):**
do **not** run the full `check.sh` (it fails fast anyway), and **never** claim a
build/test passed. Say plainly: "Verification must happen on a Mac — CI runs the
full `check.sh` on `macos-26` and is the authority on green." You may still
read/edit Swift, reason about the pipeline, and write tests for later
verification — just don't assert they pass.

What you CAN run there is the portable subset:

```bash
scripts/check.sh --portable
```

It runs the repo-integrity guards — dependencies, sound catalog, shell
portability, and settled decisions — then actionlint, zizmor, prettier, xmllint,
markdownlint, shellcheck, shfmt, ruff (lint + format check), mypy and pytest
(95% coverage gate) over `evals/`, and `release.test.sh`. `swift-format lint`,
`swiftlint lint` and `design-sync.sh --check` join them when the Linux Swift
toolchain and SwiftLint are on `PATH` — the web `SessionStart` hook installs both
(`scripts/install-linux-swift.sh` for the toolchain; run it by hand elsewhere).

That fully verifies docs, scripts, eval, and workflow changes. It is
**not** "green" in the CI sense: the build, the tests, `swiftlint analyze`,
periphery and the iOS typecheck are skipped, and the closing line says so.
**Run it before every push, Swift changes included** (the push-gate hook does) —
jscpd, the invariants, swift-format, SwiftLint and the shell/workflow/Markdown
linters catch real CI failures from here. For the rest, push and watch
`check.yml`: `compile` reports a broken test build in ~2 minutes, and the full
run the tests and static analysis.

Every push cancels the `check.yml` run in progress and restarts its ~37
minutes. When a run goes red, fix everything it names, then push once.

Quick preflight:

```bash
[ "$(uname -s)" = Darwin ] && command -v swift xcodebuild xcodegen >/dev/null 2>&1 \
  && echo "macOS toolchain present — safe to run check.sh" \
  || echo "NO toolchain — only check.sh --portable works; Swift verification happens on a Mac/CI"
```

## Run it

```bash
scripts/check.sh
```

For a fast answer on a Mac, `scripts/check.sh --lint-only` runs steps 1–5
plus swift-format, `swiftlint lint` and design-sync, then stops before
`swift test` — what CI's `lint` job runs. A green `--lint-only` is not green:
the build, the tests, `swiftlint analyze` and periphery never ran.

It runs, in order (each tool skipped with a note if absent — but on a configured
Mac they're all present, so don't treat a skip as a pass):

Everything source-only runs first, then everything that builds. That ordering is
deliberate: reversed, a compile error means the cheap checks are
never reached and their findings arrive on the next 11-minute run instead.

The read-only checks (steps 1–5, plus 12) also don't stop each other: each one
runs, failures are tallied, and the run ends with a single `error: N check(s)
failed:` list naming all of them. So one pending `swift-format` reflow no longer
hides every lint finding behind it — expect to fix a batch, not a queue.

1. repo-integrity guards: no external SPM dependencies; and sound-catalog
   integrity (every `SoundPackCatalog` voice has both cue files, no orphans, no
   duplicate or reserved ids). Both run in `--portable` too
2. shell portability (`scripts/check-portability.sh`): GNU-only idioms in
   `scripts/*.sh` and `.claude/hooks/*.sh`, which run on BSD userland (Mac, CI)
   as well as GNU (Linux sandbox). Then settled decisions
   (`scripts/check-invariants.sh`): the grep-decidable subset of AGENTS.md's
   [Settled decisions](../../../AGENTS.md#settled-decisions--dont-reintroduce-these)
   table — `AVAudioEngine` capture, a streaming or on-device path, a client-side
   cleanup pass, `LSUIElement`, a keystroke-typing injector, the production
   Keychain in tests. Each rule is pinned to its table row and its
   `project-guardrails` bullet, so editing the prose without revisiting the rule
   fails here rather than leaving a gate that enforces a reversed decision. Then
   SwiftLint's size budgets counted without SwiftLint
   (`scripts/check-swift-size.sh`: `file_length` 400, `type_body_length` ~250,
   with notes for files near either) and the test-clock rule
   (`scripts/check-test-clock.sh`: every fixed sleep or real clock in a test
   carries a `// wall-clock-ok: <reason>`). All `--portable` too
3. `swift-format lint --strict`, then `swiftlint lint --strict` (warnings are
   failures) — both source-only
4. actionlint / zizmor (workflow security) / prettier / xmllint / markdownlint /
   shellcheck / shfmt --diff
5. `ruff format --check` + `ruff check` + `mypy` over `evals/`, then `pytest`
   under coverage.py (95% line + branch, `evals/pyproject.toml`), then `release.test.sh`

   Steps 1–5 are the `--portable` subset. Everything below needs a macOS toolchain:

6. `swift test` with `-warnings-as-errors`
7. engine line-coverage gate (≥88%, `Tests/` excluded — see `MIN_COVERAGE`)
8. ThreadSanitizer + AddressSanitizer test passes
9. `xcodegen generate` for the Mac project (generated, never committed)
10. codesign-skipped app build (warnings-as-errors)
11. **CI only:** `scripts/uitest.sh` (the XCUITest bundle) and `scripts/leaks.sh`
    (whole-app leak check). Both drive the real app and seize the keyboard and
    screen, so a local run skips them with a note and the closing line says
    `ok (UI suite + leak scan NOT run …)`. That skip is by design — CI on
    `macos-26` runs them on every PR (`check.yml`'s `ui-tests` job) and is the
    authority on them. To run them on
    a Mac anyway: `BLURT_INTEGRATION_TESTS=1 scripts/check.sh`, or invoke the two
    scripts directly. Expect to lose the machine for a few minutes if you do.
12. `swiftlint analyze` (unused imports and declarations — needs the app build's compiler log) and
    `periphery scan --strict` (unused declarations — runs its own xcodebuild).
    The only two that can't move earlier.

## Interpreting the result

- **Exit 0, no `error:` lines** → green. Safe to claim passing / commit / PR.
- **Any non-zero exit** → not green. Report the failing step and its output
  verbatim; do not soften ("mostly passes") or claim success. Fix, then re-run
  the _full_ `check.sh` — a single-file `swift test --filter` is not green.
  A red run reports every independent failure it found, so read the closing
  `error: N check(s) failed:` list and fix all of them before re-running —
  stopping at the first one wastes the aggregation.
- A `note: <tool> not installed; skipping` line means coverage of that check is
  _missing_, not satisfied. On a dev Mac, run `scripts/bootstrap.sh` to install
  the toolchain rather than accepting skips.
- The UI-suite / leak-scan skip is the one exception: it's deliberate, not a
  missing tool. A local run that ends `ok (UI suite + leak scan NOT run …)` is
  green for everything it covered — just don't claim the integration suite
  passed. That answer comes from `check.yml` on the PR.

## The iPhone app

`check.sh` covers `App/BlurtiOS` with the dependency guard, the invariants and the linters, and —
off CI, when an iPhone simulator on this Xcode's iOS runtime exists — `scripts/ios-check.sh`: the
tests with `BlurtiOSCore`'s coverage gate, `swiftlint analyze`, the probe build and periphery over
the iPhone project. Without that runtime it is skipped with a note (the closing `ok` line says so)
and CI's `ios-build`, `ios-audits` and `ios-static` jobs, which run the same script's steps, are the authority; `check.sh` then runs
`scripts/ios-typecheck.sh` instead, which typechecks the iPhone targets against the Mac Catalyst
frameworks — the stand-in for a Mac with only the Command Line Tools. Locally, `scripts/ios-test.sh` runs `BlurtiOSTests` on a
simulator when Xcode is installed and enforces `BlurtiOSCore`'s line-coverage floor (`MIN_IOS_COVERAGE`, 88%;
`BLURT_IOS_SANITIZER=thread` or `address` runs the TSan / ASan pass CI's `ios-sanitizers` job
runs), and `scripts/ios-sim.sh` builds and launches the app there.
