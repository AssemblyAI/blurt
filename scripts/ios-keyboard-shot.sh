#!/bin/bash
# A screenshot of the real Blurt keyboard — the extension in its own process,
# over a text field in the app. The BlurtiOSProbe UI test launches the app on
# -BlurtProbeField with the face, taps the globe until Blurt's keyboard is up,
# and attaches the screen; this exports it.
#
#   scripts/ios-keyboard-shot.sh                                  # light
#   scripts/ios-keyboard-shot.sh --face dark --out .build/design/ext/dark.png
#
# Blurt must be enabled as a keyboard on the simulator once by hand
# (Settings → General → Keyboard → Keyboards → Add New Keyboard → Blurt).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"
DERIVED="$IOS_DERIVED"
FACE=light
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --face)
      FACE="${2:?}"
      shift 2
      ;;
    --out)
      OUT="${2:?}"
      shift 2
      ;;
    *)
      echo "usage: ios-keyboard-shot.sh [--face light|dark] [--out FILE.png]" >&2
      exit 2
      ;;
  esac
done
[ -n "$OUT" ] || OUT="$REPO_ROOT/.build/design/ext/keyboard-$FACE.png"
mkdir -p "$(dirname "$OUT")"

ios_require_device ios-keyboard-shot
ios_wait_booted "$UDID"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
# `xcodebuild test` does not reinstall a host app it thinks it has installed;
# the keyboard is inside it, so the last build is put on the simulator first.
xcodebuild build -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" "${IOS_SIM_SIGNING[@]}" -quiet
xcrun simctl install "$UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/BlurtiOS.app"
# xcodebuild hands the test runner only the environment variables prefixed
# TEST_RUNNER_; the test reads BLURT_PROBE_ARGS.
if ! TEST_RUNNER_BLURT_PROBE_ARGS="$FACE" xcodebuild test -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" \
  -scheme BlurtiOSProbe -only-testing:BlurtiOSProbe/BlurtKeyboardShot \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$WORK/shot.xcresult" "${IOS_SIM_SIGNING[@]}" -collect-test-diagnostics never -quiet; then
  # Say why, from the result bundle, before it goes.
  xcrun xcresulttool get test-results summary --path "$WORK/shot.xcresult" 2>/dev/null | python3 -c '
import json, sys
for failure in json.load(sys.stdin).get("testFailures", []):
    print("ios-keyboard-shot:", failure.get("testName", "?"), "-", failure.get("failureText", "?"))
' || true
  exit 1
fi
ios_export_attachments "$WORK/shot.xcresult" "$WORK"
if [ ! -f "$WORK/blurt-keyboard.png" ]; then
  echo "ios-keyboard-shot: no screenshot in the result bundle" >&2
  exit 1
fi
cp "$WORK/blurt-keyboard.png" "$OUT"
echo "ios-keyboard-shot: $OUT"
