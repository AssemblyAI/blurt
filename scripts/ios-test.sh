#!/bin/bash
# Run the iPhone app's unit tests (BlurtiOSTests) on a simulator.
#
#   scripts/ios-test.sh
#   BLURT_SIM_DEVICE="iPhone 17" scripts/ios-test.sh
#
# Hosted by the app, signed ad hoc, which the simulator accepts. The engine's
# own tests are `swift test` (scripts/check.sh); these cover the iPhone code's
# pure logic — the App Group contract, the keyboard's rules, term packs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${BLURT_DERIVED_DATA:-$REPO_ROOT/.build/ios-sim}"
# The named simulator, or whichever iPhone this Mac (or CI runner) has.
DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
wanted = sys.argv[1]
names = [d["name"] for rt, devs in json.load(sys.stdin)["devices"].items() if "iOS" in rt for d in devs]
print(wanted if wanted in names else next((n for n in names if n.startswith("iPhone")), ""))
' "${BLURT_SIM_DEVICE:-iPhone 18 Pro}")"
if [ -z "$DEVICE" ]; then
  echo "ios-test: no iPhone simulator available (xcrun simctl list devices)" >&2
  exit 1
fi
echo "testing on $DEVICE"

(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
xcodebuild test -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  -quiet
