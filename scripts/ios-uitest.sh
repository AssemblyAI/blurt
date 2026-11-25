#!/bin/bash
# Run the iPhone app's accessibility audits (BlurtiOSUITests) on a simulator.
#
#   scripts/ios-uitest.sh
#   BLURT_SIM_DEVICE="iPhone 17 Pro" scripts/ios-uitest.sh
#   scripts/ios-uitest.sh -only-testing:BlurtiOSUITests/AccessibilityAuditTests/testHome
#
# XCUITests that launch the app onto each of its screens and run
# `performAccessibilityAudit()` there (App/BlurtiOS/BlurtiOSUITests). Unlike the
# Mac's UI suite they never touch this Mac's keyboard or mouse — everything
# happens inside the simulator — so ios-check.sh runs them as a gate, locally
# and on CI alike. They reset the app's microphone permission on the simulator
# they run on, so name one no other run is using.
#
# Shares ios-test.sh's derived data and flags, so after it only the test
# bundle compiles.
# The per-test log, with every issue an audit raised, is in the result bundle
# the last line names.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"

ios_require_device ios-uitest
echo "auditing on $NAME"
ios_wait_booted "$UDID"

(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
ios_resolve_packages "$IOS_DERIVED"
RESULTS="$IOS_DERIVED/BlurtiOSUITests-$(date +%Y%m%d-%H%M%S).xcresult"
pretty_xcodebuild
# Serial: every test relaunches the one app on the one simulator.
xcodebuild test -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOSUITests \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$IOS_DERIVED" \
  -resultBundlePath "$RESULTS" "${IOS_SIM_SIGNING[@]}" -enableCodeCoverage YES \
  -parallel-testing-enabled NO -collect-test-diagnostics never "$@" 2>&1 | "${PRETTY[@]}"
echo "results: $RESULTS"
