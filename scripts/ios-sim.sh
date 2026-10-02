#!/bin/bash
# Build the iPhone app and run it in the iOS Simulator: the whole loop in one
# command, for anyone with Xcode and no Apple team. Signing is ad hoc, which the
# simulator accepts, and the App Group works there without provisioning, so the
# app, the keyboard and everything between them run for real; only the phone's
# microphone, background behaviour and haptics need a device.
#
#   scripts/ios-sim.sh                       # build, boot, install, launch
#   scripts/ios-sim.sh --screenshot out.png  # …then capture the screen
#   scripts/ios-sim.sh --no-build …          # reuse the last build (a capture loop builds once)
#   BLURT_SIM_DEVICE="iPhone 17" scripts/ios-sim.sh
#   BLURT_LAUNCH_ARGS="-BlurtGallery panel idle,recording" scripts/ios-sim.sh --screenshot panel.png
#   BLURT_SHOT_DELAY=5 …                     # seconds before the screenshot (default 3)
#
# The named simulator, or whichever iPhone this Mac has. Xcode 27 replaced
# Simulator.app with Device Hub; either is opened if found (neither is, with
# only the Command Line Tools selected). In Device Hub, turn off "Always
# simulate hardware keyboard" or no on-screen keyboard ever appears.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"
DERIVED="$IOS_DERIVED"
# PRODUCT_BUNDLE_IDENTIFIER in App/BlurtiOS/project.yml.
BUNDLE_ID=dev.alex.blurt.ios
SHOT=""
BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --screenshot)
      SHOT="${2:?usage: ios-sim.sh [--no-build] [--screenshot <path.png>]}"
      shift 2
      ;;
    --no-build)
      BUILD=0
      shift
      ;;
    *)
      echo "usage: ios-sim.sh [--no-build] [--screenshot <path.png>]" >&2
      exit 2
      ;;
  esac
done

APP="$DERIVED/Build/Products/Debug-iphonesimulator/BlurtiOS.app"
if [ "$BUILD" -eq 1 ]; then
  echo "generate + build"
  (cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
  xcodebuild -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
    "${IOS_SIM_SIGNING[@]}" -quiet build
elif [ ! -d "$APP" ]; then
  echo "ios-sim: --no-build but nothing built at $APP; run once without it" >&2
  exit 1
fi

PICKED="$(ios_pick_device "${BLURT_SIM_DEVICE:-iPhone 18 Pro}")"
if [ -z "$PICKED" ]; then
  echo "ios-sim: no iPhone simulator available (xcrun simctl list devices)" >&2
  exit 1
fi
UDID="${PICKED%%	*}"
NAME="${PICKED#*	}"

echo "boot $NAME ($UDID)"
ios_wait_booted "$UDID"
DEVELOPER_DIR="$(xcode-select -p)"
for app in "$DEVELOPER_DIR/../Applications/DeviceHub.app" "$DEVELOPER_DIR/Applications/Simulator.app"; do
  if [ -d "$app" ]; then
    open "$app"
    break
  fi
done

echo "install + launch"
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant microphone "$BUNDLE_ID"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
# The `+` expansion keeps an empty array from tripping `set -u` on macOS's bash 3.2.
read -ra LAUNCH_ARGS <<<"${BLURT_LAUNCH_ARGS:-}"
xcrun simctl launch "$UDID" "$BUNDLE_ID" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}

if [ -n "$SHOT" ]; then
  sleep "${BLURT_SHOT_DELAY:-3}"
  xcrun simctl io "$UDID" screenshot "$SHOT"
fi
