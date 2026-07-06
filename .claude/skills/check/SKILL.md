---
name: check
description: Verify the repo is green by running scripts/check.sh — the same full health check CI runs (swift test + coverage gate, sanitizers, xcodegen drift, app build, swift-format/swiftlint/periphery/prettier/markdownlint/shellcheck). Use before claiming a change builds, passes, or is ready to commit/PR. Bakes in the macOS-only guard so a Linux/web sandbox flags "verify on a Mac" instead of fabricating a green result; there, scripts/check.sh --portable runs the platform-independent subset (docs/site/scripts/workflows).
---

# check — is this green?

`scripts/check.sh` is the **single source of truth** for "is this green?" It is
exactly what CI (`.github/workflows/check.yml`, `macos-26`) runs, so a clean
local `check.sh` matches CI by construction.

## Before you run: the macOS-only guard

Blurt is macOS-only (`platforms: [.macOS(.v26)]`, AppKit + AVFoundation). The
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

It runs actionlint / prettier / xmllint / markdownlint / shellcheck /
`release.test.sh` (plus `swift-format lint` and `swiftlint lint` if Linux
builds are on `PATH` — under the default web network policy they are not).
That fully verifies docs, site, scripts, and workflow changes. It is **not**
"green" in the CI sense: the entire Swift side is skipped, and the closing
line says so. For Swift changes, push and watch `check.yml` instead. In
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

1. `swift test` with `-warnings-as-errors`
2. engine line-coverage gate (≥80%, `Tests/` excluded — see `MIN_COVERAGE`)
3. ThreadSanitizer + AddressSanitizer test passes
4. xcodegen drift check (regenerating must not change the committed `.pbxproj`)
5. codesign-skipped app build (warnings-as-errors)
6. `swift-format lint --strict`
7. `swiftlint lint --strict` (warnings are failures), `periphery scan --strict`
8. actionlint / prettier / xmllint / markdownlint / shellcheck

## Interpreting the result

- **Exit 0, no `error:` lines** → green. Safe to claim passing / commit / PR.
- **Any non-zero exit** → not green. Report the failing step and its output
  verbatim; do not soften ("mostly passes") or claim success. Fix, then re-run
  the _full_ `check.sh` — a single-file `swift test --filter` is not green.
- A `note: <tool> not installed; skipping` line means coverage of that check is
  _missing_, not satisfied. On a dev Mac, run `scripts/bootstrap.sh` to install
  the toolchain rather than accepting skips.
