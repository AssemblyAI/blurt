#!/bin/bash
# Build the iPhone app and run it in the iOS Simulator: the whole loop in one
# command, for anyone with Xcode and no Apple team. Signing is ad hoc, which the
# simulator accepts, and the App Group works there without provisioning, so the
# app, the keyboard and everything between them run for real; only the phone's
# microphone, background behaviour and haptics need a device.
#
#   scripts/ios-sim.sh                       # build, boot, install, launch
#   scripts/ios-sim.sh --screenshot out.png  # …then capture the screen
#   BLURT_SIM_DEVICE="iPhone 17" scripts/ios-sim.sh
#   BLURT_LAUNCH_ARGS="-BlurtGallery panel idle,recording" scripts/ios-sim.sh --screenshot panel.png
#
# Xcode 27 replaced Simulator.app with Device Hub; either is opened if found.
# In Device Hub, turn off "Always simulate hardware keyboard" or no on-screen
# keyboard ever appears.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${BLURT_SIM_DEVICE:-iPhone 18 Pro}"
DERIVED="${BLURT_DERIVED_DATA:-$REPO_ROOT/.build/ios-sim}"
BUNDLE_ID=dev.alex.blurt.ios
SHOT=""
if [ "${1:-}" = "--screenshot" ]; then
  SHOT="${2:?usage: ios-sim.sh --screenshot <path.png>}"
fi

echo "generate + build"
(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
xcodebuild -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  -quiet build

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
runtimes = json.load(sys.stdin)["devices"]
found = [(rt, d["udid"]) for rt, devs in runtimes.items() if "iOS" in rt for d in devs if d["name"] == name]
found.sort()
print(found[-1][1] if found else "")
' "$DEVICE")"
if [ -z "$UDID" ]; then
  echo "ios-sim: no available simulator named '$DEVICE' (xcrun simctl list devices)" >&2
  exit 1
fi

echo "boot $DEVICE ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
DEVELOPER_DIR="$(xcode-select -p)"
for app in "$DEVELOPER_DIR/../Applications/DeviceHub.app" "$DEVELOPER_DIR/Applications/Simulator.app"; do
  if [ -d "$app" ]; then
    open "$app"
    break
  fi
done

echo "install + launch"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/BlurtiOS.app"
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant microphone "$BUNDLE_ID"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
# The `+` expansion keeps an empty array from tripping `set -u` on macOS's bash 3.2.
read -ra LAUNCH_ARGS <<<"${BLURT_LAUNCH_ARGS:-}"
xcrun simctl launch "$UDID" "$BUNDLE_ID" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}

if [ -n "$SHOT" ]; then
  sleep 3
  xcrun simctl io "$UDID" screenshot "$SHOT"
fi
