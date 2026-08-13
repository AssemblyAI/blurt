---
name: check
description: Verify the repo is green by running scripts/check.sh — the same full health check CI runs (swift test + coverage gate, sanitizers, xcodegen drift, app build, swift-format/swiftlint/periphery/prettier/markdownlint/shellcheck/shfmt, site deployability, settled-decision invariants, ruff + pytest over evals/). Its read-only checks report together, so a red run names every failure at the bottom rather than stopping at the first. Use before claiming a change builds, passes, or is ready to commit/PR. Bakes in the macOS-only guard so a Linux/web sandbox flags "verify on a Mac" instead of fabricating a green result; there, scripts/check.sh --portable runs the platform-independent subset (docs/site/scripts/workflows).
---

# check — is this green?

`scripts/check.sh` is the **single source of truth** for "is this green?" It is
exactly what CI (`.github/workflows/check.yml`, `macos-26`) runs, so a clean
local `check.sh` matches CI by construction.

## Before you run: the macOS-only guard

Blurt is macOS-only (`platforms: [.macOS(.v15)]`, AppKit + AVFoundation). The
engine imports AVFoundation, so even the SPM package won't compile off-Mac.

**If `swift`/`xcodebuild`/`xcodegen` are unavailable (Linux or web sandbox):**
do **not** run the full `check.sh` (it fails fast anyway), and **never** claim a
build/test passed. Say plainly: "Verification must happen on a Mac — CI runs the
full `check.sh` on `macos-26` and is the authority on green." You may still
read/edit Swift, reason about the pipeline, and write tests for later
verification — just don't assert they pass.

What you CAN run there is the portable subset:

```bash
scripts/check.sh --portable
```

It runs the repo-integrity guards (dependencies, sound catalog, site, shell
portability, settled decisions) then
actionlint / zizmor / prettier / xmllint / markdownlint / shellcheck / shfmt /
ruff (lint + format check) / pytest over `evals/` / `release.test.sh` (plus `swift-format lint` and `swiftlint lint` if Linux
builds are on `PATH` — under the default web network policy they are not).
That fully verifies docs, site, scripts, eval, and workflow changes. It is **not**
"green" in the CI sense: the entire Swift side is skipped, and the closing
line says so. For Swift changes, push and watch `check.yml` instead — its
`compile` job reports a broken test build in ~2 minutes, and `format-patch`
publishes the exact `swift-format` reflow as an artifact so you don't have to
reproduce it by hand. In
Claude Code on the web, the `SessionStart` hook installs the portable
linters automatically.

Quick preflight:

```bash
command -v swift xcodebuild xcodegen >/dev/null 2>&1 \
  && echo "macOS toolchain present — safe to run check.sh" \
  || echo "NO toolchain — only check.sh --portable works; Swift verification happens on a Mac/CI"
```

## Run it

```bash
scripts/check.sh
```

It runs, in order (each tool skipped with a note if absent — but on a configured
Mac they're all present, so don't treat a skip as a pass):

Everything source-only runs first, then everything that builds. That ordering is
deliberate: reversed, a compile error means the cheap checks are
never reached and their findings arrive on the next 11-minute run instead.

The read-only checks (steps 1–5, plus 12) also don't stop each other: each one
runs, failures are tallied, and the run ends with a single `error: N check(s)
failed:` list naming all of them. So one pending `swift-format` reflow no longer
hides every lint finding behind it — expect to fix a batch, not a queue.

1. repo-integrity guards: no external SPM dependencies; sound-catalog
   integrity (every `SoundPackCatalog` voice has both cue files, no orphans, no
   duplicate or reserved ids); and site integrity (`scripts/check-site.sh` —
   the Pages site's local references, `#fragment`s, per-element hygiene,
   `CNAME` agreement with canonical/og:url/sitemap/robots, CSS `url()`, and
   no unreferenced assets). All run in `--portable` too
2. shell portability (`scripts/check-portability.sh`): GNU-only idioms in
   `scripts/*.sh` and `.claude/hooks/*.sh`, which run on BSD userland (Mac, CI)
   as well as GNU (Linux sandbox). Then settled decisions
   (`scripts/check-invariants.sh`): the grep-decidable subset of AGENTS.md's
   [Settled decisions](../../../AGENTS.md#settled-decisions--dont-reintroduce-these)
   table — `AVAudioEngine` capture, a streaming or on-device path, a client-side
   cleanup pass, `LSUIElement`, a keystroke-typing injector, the production
   Keychain in tests. Both `--portable` too
3. `swift-format lint --strict`, then `swiftlint lint --strict` (warnings are
   failures) — both source-only
4. actionlint / zizmor (workflow security) / prettier / xmllint / markdownlint /
   shellcheck / shfmt --diff
5. `ruff format --check` + `ruff check` over `evals/`, then `pytest`
   over `evals/dictation-prompt/test_eval.py`, then `release.test.sh`

   Steps 1–5 are the `--portable` subset. Everything below needs a macOS toolchain:

6. `swift test` with `-warnings-as-errors`
7. engine line-coverage gate (≥80%, `Tests/` excluded — see `MIN_COVERAGE`)
8. ThreadSanitizer + AddressSanitizer test passes
9. xcodegen drift check (regenerating must not change the committed `.pbxproj`)
10. codesign-skipped app build (warnings-as-errors)
11. **CI only:** `scripts/uitest.sh` (the XCUITest bundle) and `scripts/leaks.sh`
    (whole-app leak check). Both drive the real app and seize the keyboard and
    screen, so a local run skips them with a note and the closing line says
    `ok (UI suite + leak scan NOT run …)`. That skip is by design — CI on
    `macos-26` runs them on every PR and is the authority on them. To run them on
    a Mac anyway: `BLURT_INTEGRATION_TESTS=1 scripts/check.sh`, or invoke the two
    scripts directly. Expect to lose the machine for a few minutes if you do.
12. `swiftlint analyze` (unused imports — needs the app build's compiler log) and
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
