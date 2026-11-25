#!/bin/bash
# Run the iPhone app's accessibility audits (BlurtiOSUITests) on a simulator.
#
#   scripts/ios-uitest.sh
#   BLURT_SIM_DEVICE="iPhone 17 Pro" scripts/ios-uitest.sh
#   scripts/ios-uitest.sh -only-testing:BlurtiOSUITests/AccessibilityAuditTests/testHome
#   BLURT_AUDIT_TEXT_SIZE=largest scripts/ios-uitest.sh   # one text size only (default|largest)
#
# Arguments (-only-testing: / -skip-testing:) select tests; CI's ios-audits
# matrix splits the largest-size audits in two this way.
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
# Booting under the build, as ios-test.sh does; waited for before the run.
ios_boot_async "$UDID"

(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
ios_resolve_packages "$IOS_DERIVED"
RESULTS="$IOS_DERIVED/BlurtiOSUITests-$(date +%Y%m%d-%H%M%S).xcresult"
pretty_xcodebuild
XCODEBUILD_ARGS=(-project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOSUITests
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$IOS_DERIVED"
  "${IOS_SIM_SIGNING[@]}" -enableCodeCoverage YES)
xcodebuild build-for-testing "${XCODEBUILD_ARGS[@]}" 2>&1 | "${PRETTY[@]}"
ios_wait_booted "$UDID"
# One launch of the app before the suite. A simulator that has just finished
# booting is still busy for a while, and the app's first launch on it pays for
# registering it; the first audit (testConsent, alphabetically) bore both and
# missed its 10 s wait for the consent sheet when CI moved this suite onto a
# fresh runner. Before that it ran after ios-test, whose host-app launches had
# already warmed the simulator — this restores that, without the tests.
APP="$IOS_DERIVED/Build/Products/Debug-iphonesimulator/BlurtiOS.app"
if [ -d "$APP" ]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  sleep 10
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" || true
else
  echo "note: no $APP to warm the simulator with; running the audits cold" >&2
fi
# BLURT_AUDIT_TEXT_SIZE keeps the run to one of the two text sizes (CI's
# ios-audits matrix runs one per runner). xcodebuild hands any TEST_RUNNER_-
# prefixed variable to the test runner without the prefix.
if [ -n "${BLURT_AUDIT_TEXT_SIZE:-}" ]; then
  echo "auditing at the $BLURT_AUDIT_TEXT_SIZE text size only"
  export TEST_RUNNER_BLURT_AUDIT_TEXT_SIZE="$BLURT_AUDIT_TEXT_SIZE"
fi
# Serial: every test relaunches the one app on the one simulator. Any extra
# arguments (-only-testing:…) select tests, so they go to the run.
xcodebuild test-without-building "${XCODEBUILD_ARGS[@]}" -resultBundlePath "$RESULTS" \
  -parallel-testing-enabled NO -collect-test-diagnostics never "$@" 2>&1 | "${PRETTY[@]}"
echo "results: $RESULTS"
# A selection that matched no test (a renamed one in a shard's -only-testing
# list) would otherwise pass having audited nothing.
COUNT="$(xcrun xcresulttool get test-results summary --path "$RESULTS" 2>/dev/null \
  | python3 -c 'import json, sys; print(json.load(sys.stdin).get("totalTestCount", ""))' || true)"
if [ "$COUNT" = "0" ]; then
  echo "error: no audit ran${1:+ for $*}" >&2
  exit 1
fi
