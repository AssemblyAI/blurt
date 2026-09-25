#!/bin/bash
# Run the iPhone app's unit tests (BlurtiOSTests) on a simulator.
#
#   scripts/ios-test.sh
#   BLURT_SIM_DEVICE="iPhone 17" scripts/ios-test.sh
#
# Hosted by the app, signed ad hoc, on the named simulator or whichever iPhone
# this Mac (or CI runner) has. The engine's own tests are `swift test`
# (scripts/check.sh); these cover the iPhone code's pure logic — the App Group
# contract, the keyboard's rules, term packs. The per-test log is in the
# result bundle the last line names.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"
DERIVED="${BLURT_DERIVED_DATA:-$REPO_ROOT/.build/ios-sim}"

PICKED="$(ios_pick_device "${BLURT_SIM_DEVICE:-iPhone 18 Pro}")"
if [ -z "$PICKED" ]; then
  echo "ios-test: no iPhone simulator available (xcrun simctl list devices)" >&2
  exit 1
fi
UDID="${PICKED%%	*}"
echo "testing on ${PICKED#*	}"
ios_wait_booted "$UDID"

(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
RESULTS="$DERIVED/BlurtiOSTests-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild test -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULTS" "${IOS_SIM_SIGNING[@]}" -quiet
xcrun xcresulttool get test-results summary --path "$RESULTS" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("ios-test:", d.get("passedTests", "?"), "passed,", d.get("failedTests", "?"), "failed,", d.get("skippedTests", 0), "skipped")
' || true
echo "results: $RESULTS"
