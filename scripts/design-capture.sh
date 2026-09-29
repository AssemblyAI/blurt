#!/bin/bash
# Capture the keyboard from the simulator, one still per layout × state × theme,
# cropped to the keyboard's own pixels — the simulator side of the design loop
# (DESIGN.md › Figma). Each capture is deterministic: the gallery's
# -BlurtGalleryStill holds the orb, the ring and the wave at time zero, and
# -BlurtGalleryBare draws one row with a magenta registration border that
# scripts/design-diff.swift crops to.
#
#   scripts/design-capture.sh                                  # panel × the golden states × both faces
#   scripts/design-capture.sh --layout full --states idle,recording,error --themes dark
#   scripts/design-capture.sh --voice b                        # the ribs candidate (-BlurtGalleryVoice)
#   scripts/design-capture.sh --out .build/design/captures --no-build
#
# Writes <out>/<layout>-<state>-<theme>@3x.png (1206 px wide on iPhone 18 Pro,
# the same pixel size as a Figma export at 3×, so the diff never resamples)
# plus <out>/<layout>-<state>-<theme>.raw.png, the whole screen it was cut from.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

LAYOUT=panel
STATES=idle,recording,error,term
THEMES=light,dark
OUT="$REPO_ROOT/.build/design/captures"
VOICE=""
BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --layout)
      LAYOUT="${2:?}"
      shift 2
      ;;
    --states)
      STATES="${2:?}"
      shift 2
      ;;
    --themes)
      THEMES="${2:?}"
      shift 2
      ;;
    --out)
      OUT="${2:?}"
      shift 2
      ;;
    --voice)
      VOICE="${2:?}"
      shift 2
      ;;
    --no-build)
      BUILD=0
      shift
      ;;
    *)
      echo "usage: design-capture.sh [--layout slimBar|panel|full] [--states a,b] [--themes a,b] [--voice a|b|c] [--out DIR] [--no-build]" >&2
      exit 2
      ;;
  esac
done
mkdir -p "$OUT"

# The layout's height in points, from the tokens the views are built on, so
# the crop can assert it got the whole keyboard and nothing else.
height_pt() {
  python3 - "$1" <<'PY'
import json, sys
m = json.load(open("App/BlurtiOS/Design/tokens.json"))["metrics"]
v = lambda k: m[k]["value"] if isinstance(m[k], dict) else m[k]
print({"slimBar": v("layout/slim"), "panel": v("layout/panel"), "full": v("layout/full")}[sys.argv[1]])
PY
}
HEIGHT_PT="$(height_pt "$LAYOUT")"

# Build once; every capture after the first reuses it.
first=1
IFS=, read -ra STATE_LIST <<<"$STATES"
IFS=, read -ra THEME_LIST <<<"$THEMES"
for theme in "${THEME_LIST[@]}"; do
  for state in "${STATE_LIST[@]}"; do
    name="$LAYOUT-$state-$theme${VOICE:+-$VOICE}"
    raw="$OUT/$name.raw.png"
    flags=(--screenshot "$raw")
    if [ "$first" -eq 0 ] || [ "$BUILD" -eq 0 ]; then flags=(--no-build "${flags[@]}"); fi
    first=0
    # `landed` is a moment, not a state: the drop peaks 0.6 s after the gallery's
    # 2.4 s offset, so the default 3 s delay catches it; everything else is
    # still by construction and needs only the launch to settle.
    delay=1.5
    still=-BlurtGalleryStill
    if [ "$state" = "landed" ]; then
      delay=3
      still=""
    fi
    echo "==> $name"
    BLURT_LAUNCH_ARGS="-BlurtGallery $LAYOUT $state $theme $still -BlurtGalleryBare${VOICE:+ -BlurtGalleryVoice $VOICE}" \
      BLURT_SHOT_DELAY="$delay" scripts/ios-sim.sh "${flags[@]}" >/dev/null
    # The capture's scale: pixels across ÷ the device's points across.
    scale="$(python3 -c '
import subprocess, sys
out = subprocess.run(["sips", "-g", "pixelWidth", sys.argv[1]], capture_output=True, text=True).stdout
px = int(out.split()[-1])
print(3 if px > 1000 else 2)
' "$raw")"
    # `term` and `keys` show the full keyboard whatever layout was asked for.
    expect=$((HEIGHT_PT * scale))
    case "$state" in term | keys) expect=$(($(height_pt full) * scale)) ;; esac
    swift scripts/design-diff.swift crop "$raw" "$OUT/$name@${scale}x.png" --expect-height "$expect"
  done
done
echo "design-capture: ${#STATE_LIST[@]} × ${#THEME_LIST[@]} captures of $LAYOUT in $OUT"
