#!/bin/bash
# Project health check: build + test the SPM engine and the macOS app.
# Pipes xcodebuild through xcbeautify when available (brew install xcbeautify).
# Runs swiftlint / periphery / actionlint / zizmor / prettier / xmllint /
# markdownlint / shellcheck / shfmt / ruff / pytest when available.
# Swift warnings are treated as errors everywhere; engine line coverage is gated.
# `check.sh --portable` runs only the platform-independent subset (for Linux /
# web sandboxes with no macOS toolchain) — see the flag parsing below.
# The whole-app integration steps (the XCUITest suite and the leak scan) take
# over the keyboard and screen, so they run on CI only; set
# BLURT_INTEGRATION_TESTS=1 to include them locally — see the gate further down.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"

# --portable: run only the platform-independent checks (actionlint / zizmor /
# prettier / xmllint / markdownlint / shellcheck / shfmt / ruff / pytest /
# release.test.sh, plus swift-format and
# swiftlint lint when their Linux builds happen to be present). For Linux / web
# sandboxes where the macOS toolchain is absent. A green --portable run is NOT
# "green" in the CI sense — the Swift build, tests, sanitizers, coverage gate,
# xcodegen drift check, and app build are all SKIPPED; CI on macos-26 stays the
# authority. Without the flag, a missing toolchain fails fast here instead of
# exploding at `swift test`.
PORTABLE=0
if [ "${1:-}" = "--portable" ]; then
  PORTABLE=1
elif [ -n "${1:-}" ]; then
  echo "error: unknown argument '$1' (the only flag is --portable)" >&2
  exit 2
fi

if [ "$PORTABLE" -eq 0 ] && ! command -v swift >/dev/null 2>&1; then
  echo "error: no Swift toolchain found (Linux or web sandbox?)." >&2
  echo "       Run 'scripts/check.sh --portable' for the platform-independent subset;" >&2
  echo "       full verification happens on a Mac / CI (macos-26)." >&2
  exit 1
fi

# Engine line-coverage floor (percent). Raise as coverage grows.
# Set to 80 to accommodate untestable syscall seams (e.g. the CGEvent paste
# poster and the Accessibility reads, which the CI test process can't exercise —
# it isn't Accessibility-trusted).
MIN_COVERAGE=80

export OS_ACTIVITY_MODE=disable

# Fail the health check with a message. check.sh doesn't source release-lib.sh
# (it is not part of the release pipeline), so it carries its own.
die_check() {
  echo "error: $*" >&2
  exit 1
}

# Run one sanitizer pass of the engine suite ($1 = the --sanitize value, $2 = its
# scratch directory under .build), retrying once if it dies inside the compiler
# rather than in a test.
#
# A sanitizer scratch path outlives the toolchain that filled it. SwiftPM
# invalidates its own artifacts when the compiler or SDK moves; the Clang
# precompiled modules under `ModuleCache/` it leaves alone. A stale one then
# fails to deserialize, and the frontend dies with SIGSEGV inside
# `clang::ASTReader::finishPendingActions` while trying to diagnose the type it
# could no longer import (seen as `while resolving type , AVAudioRecorder?`).
# That failure is a convincing impostor: it reads as a compile error in engine
# code, yet it survives every source change, reproduces on a pristine checkout,
# and clears the moment that one directory goes away. It is also asymmetric —
# only the pass whose scratch path is poisoned fails, so the same `swift test`
# against the default `.build` passes and the crash looks like the sanitizer's
# doing. Observed 2026-08-11: `.build/tsan` was weeks older than the installed
# SDK, and `rm -rf` on its `ModuleCache` was the whole fix.
#
# Hence: drop just that path's module cache and run the pass again. Gated
# narrowly on the crash signature, because a detected data race or a failing test
# must never buy a silent second attempt at a multi-minute suite.
run_sanitizer_pass() {
  local sanitizer="$1"
  local scratch="$REPO_ROOT/.build/$2"
  local log status=0 crashed=0
  log="$(mktemp -t "check-sanitize-$sanitizer")"

  # tee, not capture-then-print: the pass takes minutes, and swallowing its
  # output until it finished would leave the run looking hung.
  swift test --sanitize="$sanitizer" --scratch-path "$scratch" \
    -Xswiftc -warnings-as-errors 2>&1 | tee "$log" || status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$log"
    return 0
  fi
  if grep -qE 'failed due to signal|Please submit a bug report' "$log"; then
    crashed=1
  fi
  rm -f "$log"
  [ "$crashed" -eq 1 ] || return "$status"

  echo "note: the $sanitizer pass crashed inside the compiler; clearing its stale"
  echo "      module cache ($scratch) and retrying once"
  find "$scratch" -type d -name ModuleCache -prune -exec rm -rf {} +
  swift test --sanitize="$sanitizer" --scratch-path "$scratch" -Xswiftc -warnings-as-errors
}

# Guard for the optional linters below: true when $1 is on PATH, otherwise emits
# the standard skip note (with install hint $2) and returns false. On success it
# also cds to REPO_ROOT, because every one of those checks runs from the repo
# root — so wiring up a new tool can't forget either half. Use as:
#   if tool_ready prettier 'brew install prettier'; then … fi
tool_ready() {
  if command -v "$1" >/dev/null 2>&1; then
    # `|| return 1` is load-bearing: as an `if` *condition* this function runs
    # with errexit suppressed, so a failed cd would otherwise fall through to
    # `return 0` and run the linter from the wrong directory.
    cd "$REPO_ROOT" || return 1
    return 0
  fi
  # ${2:-} so a one-arg call can't abort the whole script under `set -u` — and
  # only on a machine where the tool is missing, the hardest path to notice.
  echo "note: $1 not installed; skipping (${2:-})"
  return 1
}

# True when this is an automated run rather than someone's desktop — the one
# thing the whole-app integration steps below key off. GitHub Actions exports
# CI=true; other runners use CI=1 or just export it empty, and a developer who
# has CI=false in their shell means it. Anything else non-empty counts as CI,
# because failing *toward* running the gate is the safe direction.
is_ci() {
  case "${CI:-}" in
    "" | false | False | FALSE | 0) return 1 ;;
    *) return 0 ;;
  esac
}

# No-external-dependencies guard. The engine is dependency-free by rule and the
# app carries only the local BlurtEngine package (see AGENTS.md). A third-party
# dependency is the single biggest supply-chain risk, so fail the moment one is
# declared — in the engine's Package.swift or the app's project.yml. Extend
# BlurtEngine rather than adding a package. Pure text parsing, so it runs in
# both full and --portable modes and fails fast before the expensive steps.
echo "==> no-external-dependencies guard"
cd "$REPO_ROOT"
DEP_VIOLATION=0

# Engine: any SPM package dependency (.package(...)) is disallowed outright.
if grep -nE '\.package\(' Package.swift >/dev/null 2>&1; then
  echo "error: Package.swift declares an SPM dependency — the engine must stay dependency-free:" >&2
  grep -nE '\.package\(' Package.swift >&2
  DEP_VIOLATION=1
fi

# App: only the local BlurtEngine (path:) package is allowed. A remote package
# is declared with a url:/github: key inside project.yml's `packages:` block, so
# extract that block and reject any such key.
APP_PACKAGES="$(awk '/^packages:/{f=1;next} /^[^[:space:]]/{f=0} f' "$APP_DIR/project.yml")"
if printf '%s\n' "$APP_PACKAGES" | grep -nE '(^|[[:space:]])(url|github):' >/dev/null 2>&1; then
  echo "error: App/Blurt/project.yml declares a remote SPM package — the app must carry only the local BlurtEngine:" >&2
  printf '%s\n' "$APP_PACKAGES" | grep -nE '(^|[[:space:]])(url|github):' >&2
  DEP_VIOLATION=1
fi

[ "$DEP_VIOLATION" -eq 0 ] || exit 1
echo "no external dependencies (engine dependency-free; app carries only local BlurtEngine)"

# Ignore rules must not shadow tracked files. A .gitignore pattern only suppresses
# files that are *untracked* — one that also matches something already committed
# leaves it tracked but invisible to `git status`, so later edits to it stop
# showing up and quietly never get committed. That is the one way this file can be
# wrong and not announce itself, and the broad globs it carries (`*.log`,
# `results*.json`) are exactly the kind that drift into a collision. Pure git
# plumbing, so it runs in --portable too.
echo "==> ignore rules don't shadow tracked files"
SHADOWED="$(git ls-files --ignored --exclude-standard --cached)"
if [ -n "$SHADOWED" ]; then
  echo "error: these tracked files match an ignore rule, so git status will not report changes to them:" >&2
  printf '%s\n' "$SHADOWED" >&2
  echo "       narrow the pattern in .gitignore, or 'git rm --cached' the file if it should not be tracked." >&2
  exit 1
fi
echo "no tracked file is shadowed by an ignore rule"

# Sound-catalog integrity. `SoundPackCatalog.swift` and the cue audio are both
# emitted by scripts/generate-sounds.swift, but they land in different targets —
# engine source vs. app resources — so a partial regeneration or commit can leave
# them disagreeing. Nothing at runtime notices: `SoundPack.startFileName` names a
# stem, `Bundle.main.url(forResource:)` returns nil for it, and the cue play is a
# silent no-op, so the user picks that voice and simply hears nothing. Unit tests
# can't cover it either — the engine deliberately ships no resources, so the two
# halves only meet here. Pure text/filesystem, so it runs in --portable too.
echo "==> sound catalog integrity"
CATALOG="$REPO_ROOT/Sources/BlurtEngine/Audio/SoundPackCatalog.swift"
SOUNDS_DIR="$APP_DIR/Blurt/Resources/Sounds"
SOUND_VIOLATION=0

CATALOG_IDS="$(sed -n 's/.*SoundPack(id: "\([^"]*\)".*/\1/p' "$CATALOG" | sort)"
[ -n "$CATALOG_IDS" ] || die_check "parsed no SoundPack ids from $CATALOG — the id extraction broke"

DUPLICATE_IDS="$(printf '%s\n' "$CATALOG_IDS" | uniq -d)"
if [ -n "$DUPLICATE_IDS" ]; then
  echo "error: duplicate SoundPack ids in the catalog (find(id:) returns only the first," >&2
  echo "       and the picker would list the same voice twice):" >&2
  printf '%s\n' "$DUPLICATE_IDS" | sed 's/^/  /' >&2
  SOUND_VIOLATION=1
fi

# `none` belongs to SoundPack.none; a catalog entry claiming it would shadow the
# silent pack in `find(id:)`, so a user could never select "no sound" again.
if printf '%s\n' "$CATALOG_IDS" | grep -qx 'none'; then
  echo "error: a catalog entry uses the reserved id 'none' — it would shadow SoundPack.none" >&2
  SOUND_VIOLATION=1
fi

# Every voice needs both cues (`<id>-start.m4a` / `<id>-stop.m4a`), and every
# shipped file needs a voice — an orphan is dead weight in the app bundle and a
# sign the catalog lost an entry.
# `sort -u` so a duplicate id (already reported above) can't also fake a missing
# file here — `comm` mismatches on a repeated line and would name a file that
# exists, sending the reader after the wrong problem.
EXPECTED_SOUNDS="$(printf '%s\n' "$CATALOG_IDS" | sed -e 's/$/-start.m4a/' -e 'p' -e 's/-start\.m4a$/-stop.m4a/' | sort -u)"
ACTUAL_SOUNDS="$(find "$SOUNDS_DIR" -maxdepth 1 -name '*.m4a' | sed 's|.*/||' | sort -u)"

MISSING_SOUNDS="$(comm -23 <(printf '%s\n' "$EXPECTED_SOUNDS") <(printf '%s\n' "$ACTUAL_SOUNDS"))"
if [ -n "$MISSING_SOUNDS" ]; then
  echo "error: catalog voices with no cue audio in $SOUNDS_DIR (they would play silently):" >&2
  printf '%s\n' "$MISSING_SOUNDS" | sed 's/^/  /' >&2
  SOUND_VIOLATION=1
fi

ORPHAN_SOUNDS="$(comm -13 <(printf '%s\n' "$EXPECTED_SOUNDS") <(printf '%s\n' "$ACTUAL_SOUNDS"))"
if [ -n "$ORPHAN_SOUNDS" ]; then
  echo "error: cue audio in $SOUNDS_DIR with no catalog voice (unreachable, and shipped anyway):" >&2
  printf '%s\n' "$ORPHAN_SOUNDS" | sed 's/^/  /' >&2
  SOUND_VIOLATION=1
fi

[ "$SOUND_VIOLATION" -eq 0 ] || exit 1
echo "$(printf '%s\n' "$CATALOG_IDS" | wc -l | tr -d ' ') voices, each with both cues, no orphans"

# GitHub Pages site integrity. prettier and xmllint below cover the site's
# *formatting* and the sitemap's well-formedness; neither asks whether the page
# still works once deployed. pages.yml uploads site/ verbatim with no build
# step, so a renamed asset, a stale absolute URL, or a missing CNAME produces no
# error anywhere in this repo — just a 404 on the live site with check.sh green.
# scripts/check-site.sh closes that gap. Pure text/filesystem and deliberately
# offline (no external link fetching), so it runs in --portable too.
echo "==> site integrity"
cd "$REPO_ROOT"
bash scripts/check-site.sh

if [ "$PORTABLE" -eq 1 ]; then
  echo "==> portable mode: skipping swift test, coverage gate, sanitizers, xcodegen"
  echo "    drift check, app build, UI tests, leaks, swiftlint analyze, periphery"
else
  if command -v xcbeautify >/dev/null 2>&1; then
    PRETTY=(xcbeautify --quiet)
  else
    PRETTY=(cat)
    echo "note: xcbeautify not installed; using raw output (brew install xcbeautify)"
  fi

  echo "==> swift test (BlurtEngine)"
  cd "$REPO_ROOT"
  # -warnings-as-errors: a warning fails the build, so deprecations / unused code
  # can't accumulate. --enable-code-coverage feeds the coverage gate below.
  swift test --enable-code-coverage -Xswiftc -warnings-as-errors

  echo "==> coverage gate (>= ${MIN_COVERAGE}% engine lines)"
  BIN="$(swift build --show-bin-path)"
  PROFDATA="$BIN/codecov/default.profdata"
  XCTEST_BUNDLE="$(find "$BIN" -maxdepth 1 -name '*PackageTests.xctest' -print -quit)"
  XCTEST_BIN="$XCTEST_BUNDLE/Contents/MacOS/$(basename "$XCTEST_BUNDLE" .xctest)"
  # These must exist after `swift test --enable-code-coverage`. Previously a
  # missing one (a renamed test bundle, a coverage build that didn't happen)
  # turned the >=80% floor into a printed note and check.sh still exited 0 — the
  # gate vanished silently and CI stayed green. Fail instead.
  [ -n "$XCTEST_BUNDLE" ] || die_check "no *PackageTests.xctest found under $BIN — coverage gate cannot run"
  [ -f "$PROFDATA" ] || die_check "no coverage profile at $PROFDATA — coverage gate cannot run"
  [ -f "$XCTEST_BIN" ] || die_check "no test binary at $XCTEST_BIN — coverage gate cannot run"
  command -v python3 >/dev/null 2>&1 || die_check "python3 not found — needed to read the coverage summary"
  # Exclusions (so the figure reflects deterministically-testable engine code):
  #  - Tests/            : test files themselves, not shipping code.
  #  - MicCapture.swift  : the AVAudioRecorder capture actor. It needs a real
  #                        audio device, so it can't run in CI (its integration
  #                        test, MicCaptureLevelsTests, is env-gated for the same
  #                        reason). Its pure meter math lives in
  #                        MicCapture+Meter.swift, which IS covered. Keep this
  #                        list tight — exclude only code that genuinely cannot
  #                        be exercised without hardware.
  COVERAGE="$(xcrun llvm-cov export -summary-only -instr-profile "$PROFDATA" "$XCTEST_BIN" \
    -ignore-filename-regex='Tests/|Audio/MicCapture\.swift' \
    | python3 -c 'import sys,json; print(round(json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"],2))')"
  echo "engine line coverage: ${COVERAGE}%"
  if ! awk -v c="$COVERAGE" -v min="$MIN_COVERAGE" 'BEGIN{ exit (c+0 < min+0) }'; then
    echo "error: coverage ${COVERAGE}% is below the ${MIN_COVERAGE}% floor"
    exit 1
  fi

  echo "==> swift test --sanitize=thread (data-race detection)"
  # ThreadSanitizer instruments the build and flags unsynchronized access to
  # shared mutable state at runtime — catching data races regardless of test
  # ordering (e.g. an unguarded global touched by parallel tests). Runs the
  # suite a second time against a TSan-instrumented build.
  #
  # Each sanitizer gets its own --scratch-path: the three passes compile with
  # different swiftc flags, so sharing the default .build makes every pass
  # invalidate the previous one's artifacts (and leaves .build poisoned for the
  # next run's plain pass). Separate paths keep three warm incremental caches —
  # and `run_sanitizer_pass` handles the one way a long-lived one goes bad.
  run_sanitizer_pass thread tsan

  echo "==> swift test --sanitize=address (memory-safety detection)"
  # AddressSanitizer catches use-after-free, buffer overflows, and other memory
  # corruption at runtime. (LeakSanitizer is unsupported on Darwin, so this does
  # NOT find retain-cycle leaks — those are covered by the weak-reference
  # assertions in MemoryLeakTests.swift.)
  run_sanitizer_pass address asan

  echo "==> xcodegen (App/Blurt)"
  cd "$APP_DIR"
  PBXPROJ="Blurt.xcodeproj/project.pbxproj"
  if command -v xcodegen >/dev/null 2>&1; then
    # Drift check: regenerating must not change the on-disk project. If it does,
    # the committed .pbxproj is stale vs project.yml — fail and ask for a commit.
    BEFORE="$(shasum "$PBXPROJ" 2>/dev/null || true)"
    xcodegen generate --quiet
    AFTER="$(shasum "$PBXPROJ" 2>/dev/null || true)"
    if [ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER" ]; then
      echo "error: $PBXPROJ is out of sync with project.yml; run 'xcodegen generate' and commit it"
      exit 1
    fi
  else
    echo "note: xcodegen not installed; skipping project regeneration"
  fi

  echo "==> xcodebuild build (Blurt)"
  # Skip codesigning for the health-check build: the Developer ID cert only
  # lives on the maintainer's machine. The postBuildScripts "Install to
  # /Applications" step also bails out when CODE_SIGNING_ALLOWED=NO.
  # Warnings-as-errors for the app target is set in project.yml
  # (SWIFT_TREAT_WARNINGS_AS_ERRORS), scoped there to avoid colliding with the
  # -suppress-warnings Xcode applies to SPM dependency packages.
  # The raw build log is tee'd to $APP_BUILD_LOG so `swiftlint analyze` (below) can
  # read the compiler invocations for its analyzer rules. This build compiles both
  # the app and the engine package, so the log covers both.
  APP_BUILD_LOG="$(mktemp -t blurt-build)"
  trap 'rm -f "$APP_BUILD_LOG"' EXIT
  xcodebuild \
    -project Blurt.xcodeproj \
    -scheme Blurt \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tee "$APP_BUILD_LOG" | "${PRETTY[@]}"

  # Whole-app integration steps — CI-only by default. Both drive the *real* app,
  # and they don't just need a GUI session, they take one over: the XCUITest
  # runner steals keyboard focus and clicks for the length of the suite, and the
  # leak run launches Blurt with BLURT_LEAK_EXERCISE=1, which cycles dictation
  # through the key tap and pastes into whatever is frontmost. On a dev Mac that
  # makes the machine unusable for the several minutes they take, which is enough
  # reason on its own not to run them on every local `check.sh`.
  #
  # The gate is deliberately one-directional. Under CI they always run and there
  # is no opt-out env var, because the whole point of the required `check` status
  # is that it can't be talked out of a step — a skip flag CI honoured would be a
  # green-looking bypass of the integration suite. Off CI they're skipped with a
  # note unless BLURT_INTEGRATION_TESTS=1 asks for them; scripts/uitest.sh and
  # scripts/leaks.sh also stay runnable directly, which is the same opt-in said
  # another way. So a local run is no longer the authority on these two: CI is.
  if is_ci; then
    INTEGRATION=1
  elif [ "${BLURT_INTEGRATION_TESTS:-}" = "1" ]; then
    INTEGRATION=1
    echo "note: BLURT_INTEGRATION_TESTS=1 — running the UI suite and leak scan;"
    echo "      they drive the real app, so hands off the keyboard until they finish"
  else
    INTEGRATION=0
  fi

  if [ "$INTEGRATION" -eq 1 ]; then
    # XCUITest integration suite (BlurtUITests). Part of the required gate: it
    # drives the real app (settings flows, the menu bar item, and the record →
    # transcribe → paste pipeline against offline stubs). Delegated to
    # scripts/uitest.sh so the ad-hoc signing the runner needs is defined in
    # exactly one place. It needs a GUI session (a windowserver), which the
    # macos-26 CI runner provides.
    #
    # This cd is the one that matters: the app build above left us in $APP_DIR.
    # Both scripts run as `bash …`, i.e. in a child process that can't move this
    # shell's cwd, so nothing needs to re-cd between them.
    cd "$REPO_ROOT"
    bash scripts/uitest.sh

    # Whole-app leak check (scripts/leaks.sh). Drives the app under the Darwin
    # leak detector and fails only on leaks attributable to Blurt's own code (the
    # fixed set of system-framework XPC leaks is filtered out). Like the UI suite
    # it needs the GUI session the macos-26 runner provides.
    bash scripts/leaks.sh
  else
    echo "==> skipping the UI suite and leak scan (they take over the machine)"
    echo "    CI runs both on every PR and is the authority on them. To run them"
    echo "    here anyway: BLURT_INTEGRATION_TESTS=1 scripts/check.sh, or"
    echo "    scripts/uitest.sh / scripts/leaks.sh on their own."
  fi
fi

# Apple's swift-format (bundled with Xcode 16+) is the project's FORMATTING
# authority. --strict makes any pending formatting a non-zero exit so this
# check fails if someone forgot to run swift-format on their diff.
# Lint every tracked .swift file (git ls-files) so a new source directory is
# picked up automatically rather than silently skipped by a stale path list.
# On a Mac it runs via xcrun; a bare swift-format on PATH (e.g. a Linux build)
# works too. In portable mode a missing swift-format is a skip-note, matching
# the other optional tools; on a Mac xcrun is always present so it still runs
# unconditionally.
cd "$REPO_ROOT"
if command -v xcrun >/dev/null 2>&1; then
  SWIFT_FORMAT=(xcrun swift-format)
elif command -v swift-format >/dev/null 2>&1; then
  SWIFT_FORMAT=(swift-format)
else
  SWIFT_FORMAT=()
fi
if [ "${#SWIFT_FORMAT[@]}" -gt 0 ]; then
  echo "==> swift-format"
  git ls-files -z -- '*.swift' \
    | xargs -0 "${SWIFT_FORMAT[@]}" lint --strict
else
  echo "note: swift-format not installed; skipping (Swift formatting is checked on CI)"
fi

if tool_ready swiftlint 'brew install swiftlint'; then
  echo "==> swiftlint"
  # Covers what swift-format can't: correctness smells and complexity limits
  # (config in the sibling .swiftlint.yml). --strict promotes warnings to
  # failures, so any lint violation fails the build — keep the tree lint-clean.
  swiftlint lint --strict --quiet

  if [ "$PORTABLE" -eq 0 ]; then
    echo "==> swiftlint analyze (unused imports)"
    # Analyzer rules need the compiler invocations, so feed them the build log
    # captured above. Catches unused imports — the one dead-code gap periphery
    # (which covers unused declarations) doesn't. False positives on AVFoundation/
    # OSLog are suppressed via always_keep_imports in .swiftlint.yml.
    swiftlint analyze --strict --quiet --compiler-log-path "$APP_BUILD_LOG"
  fi
fi

if [ "$PORTABLE" -eq 0 ]; then
  if tool_ready periphery 'brew install periphery'; then
    echo "==> periphery"
    # --strict promotes any unused-code finding to a non-zero exit.
    # Periphery does its own xcodebuild + index — separate from the build above
    # because reusing DerivedData reliably across machines is fragile.
    periphery scan --strict --quiet
  fi
fi

if tool_ready actionlint 'brew install actionlint'; then
  echo "==> actionlint"
  # Auto-discovers .github/workflows, so no file list. It also pipes each `run:`
  # block through shellcheck when shellcheck is on PATH (it is, via the Brewfile),
  # which is what lint-checks the inline bash in release.yml and pr-dev-build.yml.
  actionlint
fi

if tool_ready zizmor 'brew install zizmor'; then
  echo "==> zizmor"
  # The security half of workflow lint, where actionlint is the correctness half:
  # template-injection sinks in `run:` blocks, overbroad `permissions:`, unpinned
  # action refs, credential-persistence hazards. It earns its place here because
  # release.yml hands a Developer ID signing key to a runner — the one workflow in
  # this repo where a scripting mistake costs more than a red build.
  #
  # Default persona on purpose. --persona=pedantic additionally wants a comment on
  # every `permissions:` key and flags workflow-level grants that could be
  # job-scoped; useful to run by hand, too noisy to gate on.
  #
  # --offline is already zizmor's default, but stating it keeps this check hermetic
  # by contract: a future release that flips the default to online would otherwise
  # start wanting a token and a network round-trip mid-gate. The audits it costs us
  # are the ones resolving action refs upstream, which Dependabot already watches.
  # -q drops the per-file progress chatter and the "defaulting to offline" warning,
  # keeping findings — the only thing worth reading here.
  zizmor -q --offline .github/workflows/
fi

if tool_ready prettier 'brew install prettier'; then
  echo "==> prettier --check"
  # Formatting authority for the repo's non-Swift text: CI/config (yml/yaml),
  # docs (md), and the GitHub Pages site (html/css — which also covers the
  # JSON-LD embedded in site/index.html). JSON is intentionally left out of the
  # glob: the only non-conforming file is the Xcode-generated AppIcon icon.json,
  # which must not be reformatted by hand.
  prettier --check '**/*.{yml,yaml,md,html,css}'
fi

if tool_ready xmllint 'ships with libxml2'; then
  # Prettier can't format XML without a plugin (and this repo has no JS toolchain
  # to add one), so libxml2's xmllint validates well-formedness instead — covers
  # the GitHub Pages sitemap. A parse error fails the check; --noout drops the
  # reserialized output. xmllint ships with macOS, so CI has it without a Brewfile
  # entry. Guard on an empty file list so xmllint never blocks reading stdin.
  XML_FILES="$(git ls-files '*.xml')"
  if [ -n "$XML_FILES" ]; then
    echo "==> xmllint (XML well-formedness)"
    # shellcheck disable=SC2086
    xmllint --noout $XML_FILES
  fi
fi

if tool_ready markdownlint 'brew install markdownlint-cli'; then
  echo "==> markdownlint"
  # Structural lint for the repo's Markdown (config in .markdownlint.jsonc;
  # prose-wrapping rules are off there since prettier owns Markdown formatting).
  # CLAUDE.md is a short compatibility shim that points agents at AGENTS.md, so
  # lint the canonical doc once and skip the alias file. docs/ (plans + marketing
  # drafts) is excluded too — prose, not shipped source (also in .markdownlintignore;
  # filtered here as well since the file list is passed to markdownlint as args).
  git ls-files '*.md' | grep -vx 'CLAUDE.md' | grep -vE '^docs/' | xargs markdownlint
fi

if tool_ready shellcheck 'brew install shellcheck'; then
  echo "==> shellcheck"
  # Static analysis for the project's shell scripts (release-*, check.sh
  # itself) — catches quoting bugs, unset vars, and unsafe patterns.
  #
  # The Claude Code hooks are included: they run on every file edit, so a quoting
  # bug there corrupts a source file rather than just failing a build, and nothing
  # else checked them. Both directories are passed as one invocation on purpose —
  # that puts release-lib.sh and hook-lib.sh in the input set, so the `source` lines
  # resolve instead of raising SC1091. (shfmt below deliberately still covers only
  # scripts/*.sh: the hooks predate any formatting check and haven't been reflowed.)
  shellcheck scripts/*.sh .claude/hooks/*.sh
fi

if tool_ready shfmt 'brew install shfmt'; then
  echo "==> shfmt --diff"
  # Formatting authority for scripts/*.sh, the same division of labour swift-format
  # and swiftlint have: shfmt owns layout, shellcheck owns correctness. --diff
  # prints what it would change and exits non-zero, so an unformatted script fails
  # here instead of drifting. No formatting flags on purpose — that is what lets
  # shfmt read the [*.sh] block in .editorconfig, so editors and this check agree.
  shfmt --diff scripts/*.sh
fi

# The evals (evals/) are the repo's only Python: offline decision support for the
# dictation API's cleanup instruction, not shipped code. Linted, formatted, and
# tested here anyway — a harness whose own correctness is unchecked is a bad
# instrument, and all three tools are platform-independent, so they run in the
# --portable subset too.
if tool_ready ruff 'brew install ruff'; then
  echo "==> ruff format --check (evals)"
  # Formatting authority for the Python, config in evals/ruff.toml. --check is the
  # non-mutating half; run `ruff format evals/` to fix.
  ruff format --check evals/
  echo "==> ruff check (evals)"
  # Lint: pyflakes/pycodestyle correctness plus import order, pyupgrade, and
  # bugbear. Line width is deliberately left to the formatter (see the config).
  ruff check evals/
fi

if tool_ready pytest 'brew install pytest'; then
  echo "==> pytest (evals/dictation-prompt)"
  # The eval's offline suite: corpus construction, disfluency injection, the
  # scoring metric, and the split disjointness. It needs no network, no API key,
  # and no third-party packages beyond pytest itself — everything that imports
  # DSPy lives in program.py, which these tests assert never gets imported. That
  # property is why this is cheap enough to gate on.
  pytest -q evals/dictation-prompt/test_eval.py
fi

echo "==> release-lib.sh unit tests"
cd "$REPO_ROOT"
# Pure-bash unit tests for the release orchestrator's decision helpers. No Mac
# or network dependencies, so they run everywhere check.sh runs.
bash scripts/release.test.sh

if [ "$PORTABLE" -eq 1 ]; then
  echo "==> ok (portable subset only — Swift build/tests NOT run; CI on macos-26 is the authority on green)"
elif [ "${INTEGRATION:-0}" -eq 0 ]; then
  # Say it at the end too, where the reader is deciding whether this run means
  # "green": everything else passed, but the UI suite and leak scan did not run.
  echo "==> ok (UI suite + leak scan NOT run — CI on macos-26 covers those)"
else
  echo "==> ok"
fi
