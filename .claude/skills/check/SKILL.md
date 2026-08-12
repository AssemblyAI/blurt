---
name: check
description: Verify the repo is green by running scripts/check.sh — the same full health check CI runs (swift test + coverage gate, sanitizers, xcodegen drift, app build, swift-format/swiftlint/periphery/prettier/markdownlint/shellcheck/shfmt, site deployability, ruff + pytest over evals/). Use before claiming a change builds, passes, or is ready to commit/PR. Bakes in the macOS-only guard so a Linux/web sandbox flags "verify on a Mac" instead of fabricating a green result; there, scripts/check.sh --portable runs the platform-independent subset (docs/site/scripts/workflows).
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

It runs the repo-integrity guards (dependencies, sound catalog, site — the
last needs the html-proofer gem) then
actionlint / prettier / xmllint / markdownlint / shellcheck / shfmt /
ruff (lint + format check) / pytest over `evals/` / `release.test.sh` (plus `swift-format lint` and `swiftlint lint` if Linux
builds are on `PATH` — under the default web network policy they are not).
That fully verifies docs, site, scripts, eval, and workflow changes. It is **not**
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

1. repo-integrity guards: no external SPM dependencies; sound-catalog
   integrity (every `SoundPackCatalog` voice has both cue files, no orphans, no
   duplicate or reserved ids); and site integrity (`scripts/check-site.sh` —
   html-proofer for the Pages site's links/images/srcset/favicon/Open Graph,
   plus `CNAME` agreement with canonical/og:url/sitemap/robots, CSS `url()`, and
   no unreferenced assets). All run in `--portable` too
2. `swift test` with `-warnings-as-errors`
3. engine line-coverage gate (≥80%, `Tests/` excluded — see `MIN_COVERAGE`)
4. ThreadSanitizer + AddressSanitizer test passes
5. xcodegen drift check (regenerating must not change the committed `.pbxproj`)
6. codesign-skipped app build (warnings-as-errors)
7. `scripts/uitest.sh` (the XCUITest bundle) and `scripts/leaks.sh` (whole-app
   leak check) — both need a GUI session, which the `macos-26` runner provides
8. `swift-format lint --strict`
9. `swiftlint lint --strict` (warnings are failures), `swiftlint analyze`
   (unused imports), `periphery scan --strict`
10. actionlint / prettier / xmllint / markdownlint / shellcheck / shfmt --diff
11. `ruff format --check` + `ruff check` over `evals/`, then `pytest`
    over `evals/dictation-prompt/test_eval.py`
12. `release.test.sh`

## Interpreting the result

- **Exit 0, no `error:` lines** → green. Safe to claim passing / commit / PR.
- **Any non-zero exit** → not green. Report the failing step and its output
  verbatim; do not soften ("mostly passes") or claim success. Fix, then re-run
  the _full_ `check.sh` — a single-file `swift test --filter` is not green.
- A `note: <tool> not installed; skipping` line means coverage of that check is
  _missing_, not satisfied. On a dev Mac, run `scripts/bootstrap.sh` to install
  the toolchain rather than accepting skips.
