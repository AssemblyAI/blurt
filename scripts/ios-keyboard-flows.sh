#!/bin/bash
# Drive the real Blurt keyboard through its flows in the simulator — the
# extension in its own process over a field in the app, with the app
# listening — for each face × mic concept × layout, and collect a screenshot
# of every step. The truth about the keyboard as used, which the gallery
# (the app's process, no host, no touches) cannot give.
#
#   scripts/ios-keyboard-flows.sh                       # the whole matrix
#   scripts/ios-keyboard-flows.sh --face dark --voice a --layout panel
#
# Prints one FLOW-OK / FLOW-FAIL line per step; screenshots land in
# .build/design/flows/<face>-<voice>-<layout>/. Blurt must be enabled as a
# keyboard on the simulator once by hand.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"
DERIVED="${BLURT_DERIVED_DATA:-$REPO_ROOT/.build/ios-sim}"
FACES="light dark"
VOICES="a b c"
LAYOUTS="panel full slimBar"
OUT="$REPO_ROOT/.build/design/flows"
while [ $# -gt 0 ]; do
  case "$1" in
    --face)
      FACES="${2:?}"
      shift 2
      ;;
    --voice)
      VOICES="${2:?}"
      shift 2
      ;;
    --layout)
      LAYOUTS="${2:?}"
      shift 2
      ;;
    --out)
      OUT="${2:?}"
      shift 2
      ;;
    *)
      echo "usage: ios-keyboard-flows.sh [--face light|dark] [--voice a|b|c] [--layout slimBar|panel|full] [--out DIR]" >&2
      exit 2
      ;;
  esac
done

PICKED="$(ios_pick_device "${BLURT_SIM_DEVICE:-iPhone 18 Pro}")"
[ -n "$PICKED" ] || {
  echo "ios-keyboard-flows: no iPhone simulator available" >&2
  exit 1
}
UDID="${PICKED%%	*}"
ios_wait_booted "$UDID"

(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
xcodebuild build -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" "${IOS_SIM_SIGNING[@]}" -quiet
xcrun simctl install "$UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/BlurtiOS.app"
xcrun simctl privacy "$UDID" grant microphone dev.alex.blurt.ios

for face in $FACES; do
  xcrun simctl ui "$UDID" appearance "$face"
  for voice in $VOICES; do
    for layout in $LAYOUTS; do
      name="$face-$voice-$layout"
      dir="$OUT/$name"
      rm -rf "$dir"
      mkdir -p "$dir"
      echo "==> $name"
      TEST_RUNNER_BLURT_PROBE_ARGS="$face $voice $layout" xcodebuild test \
        -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOSProbe \
        -only-testing:BlurtiOSProbe/BlurtKeyboardFlows \
        -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
        -resultBundlePath "$dir/flows.xcresult" "${IOS_SIM_SIGNING[@]}" -collect-test-diagnostics never \
        2>&1 | grep -E "^FLOW-|XCTAssertTrue failed|Blurt never came up|error:|TEST BUILD FAILED" | grep -v "XCTAssertTrue failed" | sed "s/^/    /"
      if grep -q "FLOW-FAIL\|failed" "$dir/flows.xcresult/Info.plist" 2>/dev/null; then :; fi
      xcrun xcresulttool export attachments --path "$dir/flows.xcresult" --output-path "$dir/attachments" >/dev/null 2>&1
      python3 - "$dir" <<'PY'
import json, os, shutil, sys
d = sys.argv[1]
try:
    manifest = json.load(open(os.path.join(d, "attachments", "manifest.json")))
except FileNotFoundError:
    sys.exit(0)
for test in manifest:
    for a in test.get("attachments", []):
        name = a["suggestedHumanReadableName"]
        if name.startswith("flow-"):
            shutil.copy(os.path.join(d, "attachments", a["exportedFileName"]), os.path.join(d, name.split("_")[0] + ".png"))
PY
    done
  done
done
xcrun simctl ui "$UDID" appearance light
echo "ios-keyboard-flows: screenshots in $OUT"
