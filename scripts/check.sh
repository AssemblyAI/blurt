#!/bin/bash
# Project health check: build + test the SPM engine and the macOS app.
# Pipes xcodebuild through xcbeautify when available (brew install xcbeautify).
# Runs swiftlint / periphery / actionlint / prettier / xmllint /
# markdownlint / shellcheck when available.
# Swift warnings are treated as errors everywhere; engine line coverage is gated.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"

# Engine line-coverage floor (percent). Raise as coverage grows.
# Set to 80 to accommodate untestable syscall seams (e.g. the CGEvent paste
# poster and the Accessibility reads, which the CI test process can't exercise —
# it isn't Accessibility-trusted).
MIN_COVERAGE=80

export OS_ACTIVITY_MODE=disable

if command -v xcbeautify >/dev/null 2>&1; then
  PRETTY=(xcbeautify --quiet)
else
  PRETTY=(cat)
  echo "note: xcbeautify not installed; using raw output (brew install xcbeautify)"
fi

run_xcodebuild() {
  set -o pipefail
  xcodebuild "$@" | "${PRETTY[@]}"
}

echo "==> swift test (BlurtEngine)"
cd "$REPO_ROOT"
# -warnings-as-errors: a warning fails the build, so deprecations / unused code
# can't accumulate. --enable-code-coverage feeds the coverage gate below.
swift test --enable-code-coverage -Xswiftc -warnings-as-errors

echo "==> coverage gate (>= ${MIN_COVERAGE}% engine lines)"
BIN="$(swift build --show-bin-path)"
PROFDATA="$BIN/codecov/default.profdata"
XCTEST_BIN="$(find "$BIN" -maxdepth 1 -name '*PackageTests.xctest' -print -quit)/Contents/MacOS/$(
  find "$BIN" -maxdepth 1 -name '*PackageTests.xctest' -exec basename {} .xctest \; -quit)"
if command -v python3 >/dev/null 2>&1 && [ -f "$PROFDATA" ] && [ -f "$XCTEST_BIN" ]; then
  # Exclusions (so the figure reflects deterministically-testable engine code):
  #  - Tests/            : test files themselves, not shipping code.
  #  - MicCapture.swift  : the AVAudioEngine capture actor. It needs a real audio
  #                        device, so it can't run in CI (its integration test,
  #                        MicCaptureLevelsTests, is env-gated for the same
  #                        reason). Its pure DSP lives in AudioDSP.swift, which IS
  #                        covered. Keep this list tight — exclude only code that
  #                        genuinely cannot be exercised without hardware.
  COVERAGE="$(xcrun llvm-cov export -summary-only -instr-profile "$PROFDATA" "$XCTEST_BIN" \
    -ignore-filename-regex='Tests/|Audio/MicCapture\.swift' \
    | python3 -c 'import sys,json; print(round(json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"],2))')"
  echo "engine line coverage: ${COVERAGE}%"
  if ! awk -v c="$COVERAGE" -v min="$MIN_COVERAGE" 'BEGIN{ exit (c+0 < min+0) }'; then
    echo "error: coverage ${COVERAGE}% is below the ${MIN_COVERAGE}% floor"
    exit 1
  fi
else
  echo "note: skipping coverage gate (need python3 + a coverage build)"
fi

echo "==> swift test --sanitize=thread (data-race detection)"
# ThreadSanitizer instruments the build and flags unsynchronized access to
# shared mutable state at runtime — catching data races regardless of test
# ordering (e.g. an unguarded global touched by parallel tests). Runs the
# suite a second time against a TSan-instrumented build.
swift test --sanitize=thread -Xswiftc -warnings-as-errors

echo "==> swift test --sanitize=address (memory-safety detection)"
# AddressSanitizer catches use-after-free, buffer overflows, and other memory
# corruption at runtime. (LeakSanitizer is unsupported on Darwin, so this does
# NOT find retain-cycle leaks — those are covered by the weak-reference
# assertions in MemoryLeakTests.swift.)
swift test --sanitize=address -Xswiftc -warnings-as-errors

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
set -o pipefail
xcodebuild \
  -project Blurt.xcodeproj \
  -scheme Blurt \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$APP_BUILD_LOG" | "${PRETTY[@]}"

# XCUITest integration suite (BlurtUITests). Part of the required gate: it drives
# the real app (settings flows, the menu bar item, and the record → transcribe →
# paste pipeline against offline stubs). Delegated to scripts/uitest.sh so the
# ad-hoc signing the runner needs is defined in exactly one place. It needs a GUI
# session (a windowserver), which the macos-26 CI runner provides.
cd "$REPO_ROOT"
bash scripts/uitest.sh

# Whole-app leak check (scripts/leaks.sh). Drives the app under the Darwin leak
# detector and fails only on leaks attributable to Blurt's own code (the fixed
# set of system-framework XPC leaks is filtered out). Like the UI suite it needs
# the GUI session the macos-26 runner provides.
cd "$REPO_ROOT"
bash scripts/leaks.sh

echo "==> swift-format"
cd "$REPO_ROOT"
# Apple's swift-format (bundled with Xcode 16+) is the project's FORMATTING
# authority. --strict makes any pending formatting a non-zero exit so this
# check fails if someone forgot to run swift-format on their diff.
find Sources Tests App/Blurt/Blurt App/Blurt/BlurtUITests scripts -name '*.swift' -print0 \
  | xargs -0 xcrun swift-format lint --strict

if command -v swiftlint >/dev/null 2>&1; then
  echo "==> swiftlint"
  cd "$REPO_ROOT"
  # Covers what swift-format can't: correctness smells and complexity limits
  # (config in the sibling .swiftlint.yml). --strict promotes warnings to
  # failures, so any lint violation fails the build — keep the tree lint-clean.
  swiftlint lint --strict --quiet

  echo "==> swiftlint analyze (unused imports)"
  # Analyzer rules need the compiler invocations, so feed them the build log
  # captured above. Catches unused imports — the one dead-code gap periphery
  # (which covers unused declarations) doesn't. False positives on AVFoundation/
  # OSLog are suppressed via always_keep_imports in .swiftlint.yml.
  swiftlint analyze --strict --quiet --compiler-log-path "$APP_BUILD_LOG"
else
  echo "note: swiftlint not installed; skipping (brew install swiftlint)"
fi

if command -v periphery >/dev/null 2>&1; then
  echo "==> periphery"
  cd "$REPO_ROOT"
  # --strict promotes any unused-code finding to a non-zero exit.
  # Periphery does its own xcodebuild + index — separate from the build above
  # because reusing DerivedData reliably across machines is fragile.
  periphery scan --strict --quiet
else
  echo "note: periphery not installed; skipping (brew install periphery)"
fi

if command -v actionlint >/dev/null 2>&1; then
  echo "==> actionlint"
  cd "$REPO_ROOT"
  actionlint
else
  echo "note: actionlint not installed; skipping (brew install actionlint)"
fi

if command -v prettier >/dev/null 2>&1; then
  echo "==> prettier --check"
  cd "$REPO_ROOT"
  # Formatting authority for the repo's non-Swift text: CI/config (yml/yaml),
  # docs (md), and the GitHub Pages site (html/css — which also covers the
  # JSON-LD embedded in site/index.html). JSON is intentionally left out of the
  # glob: the only non-conforming file is the Xcode-generated AppIcon icon.json,
  # which must not be reformatted by hand.
  prettier --check '**/*.{yml,yaml,md,html,css}'
else
  echo "note: prettier not installed; skipping (brew install prettier)"
fi

if command -v xmllint >/dev/null 2>&1; then
  cd "$REPO_ROOT"
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
else
  echo "note: xmllint not installed; skipping XML check (ships with libxml2)"
fi

if command -v markdownlint >/dev/null 2>&1; then
  echo "==> markdownlint"
  cd "$REPO_ROOT"
  # Structural lint for the repo's Markdown (config in .markdownlint.jsonc;
  # prose-wrapping rules are off there since prettier owns Markdown formatting).
  # CLAUDE.md is a short compatibility shim that points agents at AGENTS.md, so
  # lint the canonical doc once and skip the alias file. docs/ (plans + marketing
  # drafts) is excluded too — prose, not shipped source (also in .markdownlintignore;
  # filtered here as well since the file list is passed to markdownlint as args).
  git ls-files '*.md' | grep -vx 'CLAUDE.md' | grep -vE '^docs/' | xargs markdownlint
else
  echo "note: markdownlint not installed; skipping (brew install markdownlint-cli)"
fi

if command -v shellcheck >/dev/null 2>&1; then
  echo "==> shellcheck"
  cd "$REPO_ROOT"
  # Static analysis for the project's shell scripts (release-*, check.sh
  # itself) — catches quoting bugs, unset vars, and unsafe patterns.
  shellcheck scripts/*.sh
else
  echo "note: shellcheck not installed; skipping (brew install shellcheck)"
fi

echo "==> release.sh unit tests"
cd "$REPO_ROOT"
# Pure-bash unit tests for the release orchestrator's decision helpers. No Mac
# or network dependencies, so they run everywhere check.sh runs.
bash scripts/release.test.sh

echo "==> ok"
