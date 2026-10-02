#!/bin/bash
# The iPhone code's quality gates, in one place — what check.sh is for the Mac.
#
#   scripts/ios-check.sh
#   BLURT_SIM_DEVICE="iPhone 17" scripts/ios-check.sh
#
# The same bar the engine and the Mac shell meet in check.sh, applied to
# App/BlurtiOS:
#   1. BlurtiOSTests on a simulator, warnings as errors, with BlurtiOSCore's
#      line-coverage gate (ios-test.sh; the TSan and ASan passes are its
#      BLURT_IOS_SANITIZER runs, CI's ios-sanitizers job).
#   2. `swiftlint analyze` — unused imports — over that build's compiler log,
#      as check.sh runs it over the Mac app's.
#   3. periphery over the iPhone project — unused declarations.
# swift-format, `swiftlint lint`, the invariants and ios-typecheck.sh already
# cover App/BlurtiOS from check.sh, which reads every tracked Swift file.
#
# CI's ios-build job runs this; check.sh runs it too on a Mac with an iPhone
# simulator, so a local green means the same thing on both platforms. Like
# check.sh, every step reports, so one failure doesn't hide the next.
#
# `swiftlint analyze` sees the files the build actually compiled. CI's build is
# from scratch, so it sees everything; a local incremental one may not —
# delete .build/ios-sim for a full local pass, as with check.sh's app build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

for tool in swiftlint periphery xcodegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ios-check: $tool not found — scripts/bootstrap.sh installs it" >&2
    exit 1
  fi
done

FAILED=()
BUILD_LOG="$(mktemp -t blurt-ios-build)"
trap 'rm -f "$BUILD_LOG"' EXIT

echo "==> ios-test (BlurtiOSTests + BlurtiOSCore coverage gate)"
BLURT_IOS_BUILD_LOG="$BUILD_LOG" "$REPO_ROOT/scripts/ios-test.sh" || FAILED+=("ios-test")

echo "==> swiftlint analyze (unused imports, App/BlurtiOS)"
if [ -s "$BUILD_LOG" ]; then
  # App/BlurtiOS only. The log also compiles the engine — for iOS, where its
  # `#if os(macOS)` files are inactive and SourceKit can't resolve them — and
  # check.sh already analyzes the engine from the Mac build, where they're live.
  # SourceKit still loads those engine files to resolve the iPhone ones and
  # prints their unresolvable macOS imports to stderr — a diagnostic line, then
  # the source line and a caret. They are not findings (violations go to
  # stdout, and the exit status is the verdict), so each such block is dropped
  # whole; any other line, swiftlint's own errors included, still shows.
  swiftlint analyze --strict --quiet --compiler-log-path "$BUILD_LOG" App/BlurtiOS \
    2> >(awk -v engine="$REPO_ROOT/Sources/BlurtEngine/" '
      /^\// || /^(Error|error|warning|Fatal)/ { skip = (index($0, engine) == 1) }
      !skip { print }' >&2) || FAILED+=("swiftlint analyze")
else
  echo "error: no build log to analyze — the build above did not run" >&2
  FAILED+=("swiftlint analyze")
fi

echo "==> periphery (App/BlurtiOS)"
# `--retain-public`: the engine's public API is used by the Mac app this scan
# can't see, and the engine's own findings are excluded from the report, so only
# the iPhone code's dead declarations are reported. BlurtiOSCore's API is
# `package`, not public, so it is still scanned.
periphery scan --project App/BlurtiOS/BlurtiOS.xcodeproj --schemes BlurtiOS \
  --retain-public --retain-unused-protocol-func-params \
  --report-exclude 'Sources/**' --strict --quiet || FAILED+=("periphery")

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "error: ${#FAILED[@]} iPhone check(s) failed:" >&2
  printf '         %s\n' "${FAILED[@]}" >&2
  exit 1
fi
echo "==> ios-check: ok"
