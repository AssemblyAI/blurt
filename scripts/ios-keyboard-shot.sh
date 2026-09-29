#!/bin/bash
# A screenshot of the real Blurt keyboard — the extension in its own process,
# over a text field in the app — as the gallery cannot take one: what renders
# in the app's process (the gallery, the home hero) can differ from what the
# extension may draw. The BlurtiOSProbe UI test launches the app on
# -BlurtProbeField, which sets the face, the mic concept and the layout in the
# App Group, taps the globe until Blurt's keyboard is up, and attaches the
# screen; this exports it.
#
#   scripts/ios-keyboard-shot.sh                                  # light, the shipped mic, the saved layout
#   scripts/ios-keyboard-shot.sh --face dark --voice b --layout panel --out .build/design/ext/panel-b.png
#
# Blurt must be enabled as a keyboard on the simulator once by hand
# (Settings → General → Keyboard → Keyboards → Add New Keyboard → Blurt).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"
DERIVED="${BLURT_DERIVED_DATA:-$REPO_ROOT/.build/ios-sim}"
FACE=light
VOICE=""
LAYOUT=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --face)
      FACE="${2:?}"
      shift 2
      ;;
    --voice)
      VOICE="${2:?}"
      shift 2
      ;;
    --layout)
      LAYOUT="${2:?}"
      shift 2
      ;;
    --out)
      OUT="${2:?}"
      shift 2
      ;;
    *)
      echo "usage: ios-keyboard-shot.sh [--face light|dark] [--voice a|b|c] [--layout slimBar|panel|full] [--out FILE.png]" >&2
      exit 2
      ;;
  esac
done
[ -n "$OUT" ] || OUT="$REPO_ROOT/.build/design/ext/keyboard-$FACE${VOICE:+-$VOICE}${LAYOUT:+-$LAYOUT}.png"
mkdir -p "$(dirname "$OUT")"

PICKED="$(ios_pick_device "${BLURT_SIM_DEVICE:-iPhone 18 Pro}")"
[ -n "$PICKED" ] || {
  echo "ios-keyboard-shot: no iPhone simulator available" >&2
  exit 1
}
UDID="${PICKED%%	*}"
ios_wait_booted "$UDID"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
# xcodebuild hands the test runner only the environment variables prefixed
# TEST_RUNNER_; the test reads BLURT_PROBE_ARGS.
if ! TEST_RUNNER_BLURT_PROBE_ARGS="$FACE $VOICE $LAYOUT" xcodebuild test -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" \
  -scheme BlurtiOSProbe -only-testing:BlurtiOSProbe/BlurtKeyboardShot \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$WORK/shot.xcresult" "${IOS_SIM_SIGNING[@]}" -collect-test-diagnostics never -quiet; then
  # Say why, from the result bundle, before it goes.
  xcrun xcresulttool get test-results tests --path "$WORK/shot.xcresult" 2>/dev/null | python3 -c '
import json, sys
def walk(node):
    if isinstance(node, dict):
        if node.get("nodeType") == "Failure Message": print("ios-keyboard-shot:", node.get("name"))
        for child in node.get("children", []): walk(child)
    elif isinstance(node, list):
        for child in node: walk(child)
walk(json.load(sys.stdin).get("testNodes", []))
' || true
  exit 1
fi
xcrun xcresulttool export attachments --path "$WORK/shot.xcresult" --output-path "$WORK/attachments" >/dev/null
python3 - "$WORK/attachments" "$OUT" <<'PY'
import json, os, shutil, sys
attachments, out = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(attachments, "manifest.json")))
for test in manifest:
    for a in test.get("attachments", []):
        if a["suggestedHumanReadableName"].startswith("blurt-keyboard"):
            shutil.copy(os.path.join(attachments, a["exportedFileName"]), out)
            print(f"ios-keyboard-shot: {out}")
            sys.exit(0)
sys.exit("ios-keyboard-shot: no screenshot in the result bundle")
PY
