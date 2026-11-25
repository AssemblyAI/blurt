#!/bin/bash
# Run the XCUITest integration suite (BlurtUITests) against a Debug build of the
# Blurt app launched in UI-test mode (the `-BlurtUITest` harness in
# the UITest*.swift files). macOS-only; needs Xcode. See App/Blurt/BlurtUITests/.
#
# check.sh runs this same suite as part of the required gate; this script is the
# standalone entry point (faster to iterate on, no engine/lint steps first).
#
#   scripts/uitest.sh                                         # the whole suite
#   scripts/uitest.sh -only-testing:BlurtUITests/SettingsUITests   # a selection
#
# Arguments, if any, replace the default `-only-testing:BlurtUITests` as the
# test selection (`-only-testing:` / `-skip-testing:`): CI's ui-tests matrix runs
# the suite in two shards this way. With BLURT_UITEST_RESULTS set, a selection
# that ran no tests fails rather than passing empty — a renamed class must not
# quietly drop out of a shard's list.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"

export OS_ACTIVITY_MODE=disable

# For `pretty_xcodebuild`, as dev-build.sh does. (check.sh keeps its own copy on
# purpose — see the `die_check` note there.)
# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

pretty_xcodebuild

echo "==> xcodebuild test (BlurtUITests)"
cd "$APP_DIR"
set -o pipefail
# Ad-hoc signing (identity "-", signing ALLOWED) — NOT disabled. A UI-test
# runner must carry a real code signature: the linker-only ad-hoc that
# CODE_SIGNING_ALLOWED=NO leaves behind omits the `get-task-allow` entitlement
# the test infrastructure needs to attach, so the runner is SIGKILLed before it
# connects. Ad-hoc signing embeds it (and the app under test only ever runs from
# DerivedData). The Developer ID cert still isn't required: the app target's
# "Install to /Applications" post-build script skips itself under the "-"
# identity (see project.yml), so nothing tries to sign with it.
# -testPlan Blurt: run under Blurt.xctestplan, which retries a failing UI test
# (up to 3 attempts) so a flake isn't an immediate red, and keeps screenshots +
# attachments on the .xcresult for debugging a genuine failure on CI.
# BLURT_UITEST_RESULTS names where that .xcresult goes (CI uploads it when the
# job fails); unset, xcodebuild keeps it in DerivedData as usual. xcodebuild
# refuses to write over an existing bundle, so a stale one is removed first.
# Tested with $#, not the array: bash 3.2 (/bin/bash on macOS) calls an empty
# array unbound under `set -u`.
if [ "$#" -eq 0 ]; then
  SELECTION=(-only-testing:BlurtUITests)
else
  SELECTION=("$@")
fi
RESULT_FLAGS=()
if [ -n "${BLURT_UITEST_RESULTS:-}" ]; then
  rm -rf "$BLURT_UITEST_RESULTS"
  RESULT_FLAGS=(-resultBundlePath "$BLURT_UITEST_RESULTS")
fi
xcodebuild \
  -project Blurt.xcodeproj \
  -scheme Blurt \
  -testPlan Blurt \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  "${SELECTION[@]}" \
  ${RESULT_FLAGS[@]+"${RESULT_FLAGS[@]}"} \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  test | "${PRETTY[@]}"

if [ -n "${BLURT_UITEST_RESULTS:-}" ]; then
  TOTAL="$(xcrun xcresulttool get test-results summary --path "$BLURT_UITEST_RESULTS" 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("totalTestCount", ""))' || true)"
  if [ "$TOTAL" = "0" ]; then
    echo "error: the selection (${SELECTION[*]}) ran no tests" >&2
    exit 1
  fi
  echo "==> ${TOTAL:-?} tests in this selection"
fi
echo "==> ok"
