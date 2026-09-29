#!/bin/bash
# Record the keyboard's motion from the simulator: the gallery's `live` state
# walks a whole dictation on a clock (about 11.7 s a cycle), this records two
# cycles and cuts one clean loop, cropped to the keyboard, for the review packet
# and for the Figma motion page's keyframes (DESIGN.md › Figma).
#
#   scripts/ios-record.sh                          # panel, dark → .build/design/loops/panel-dark.mp4
#   scripts/ios-record.sh --layout slimBar --theme light --out ~/Desktop/blurt-review
#   scripts/ios-record.sh --frames 0,0.35,0.7      # also grab stills at these seconds into the loop
#
# Needs ffmpeg (Brewfile). The crop comes from a still capture of the same
# layout taken first, so the video's frame is the keyboard's own pixels.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"

LAYOUT=panel
THEME=dark
OUT="$REPO_ROOT/.build/design/loops"
FRAMES=""
CYCLE=11.7
BUILD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --layout)
      LAYOUT="${2:?}"
      shift 2
      ;;
    --theme)
      THEME="${2:?}"
      shift 2
      ;;
    --out)
      OUT="${2:?}"
      shift 2
      ;;
    --frames)
      FRAMES="${2:?}"
      shift 2
      ;;
    --no-build)
      BUILD=(--no-build)
      shift
      ;;
    *)
      echo "usage: ios-record.sh [--layout L] [--theme T] [--out DIR] [--frames s,s,…] [--no-build]" >&2
      exit 2
      ;;
  esac
done
command -v ffmpeg >/dev/null || {
  echo "ios-record: ffmpeg not installed (brew bundle)" >&2
  exit 1
}
mkdir -p "$OUT"
name="$LAYOUT-$THEME"

# A still first: it builds, boots, and gives the crop rectangle.
scripts/design-capture.sh --layout "$LAYOUT" --states idle --themes "$THEME" --out "$OUT/.still" \
  ${BUILD[@]+"${BUILD[@]}"} >/dev/null
raw="$OUT/.still/$LAYOUT-idle-$THEME.raw.png"
read -r CROP_W CROP_H CROP_X CROP_Y < <(swift scripts/design-diff.swift crop "$raw" "$OUT/.still/crop-probe.png" \
  | sed -E 's/crop: ([0-9]+)×([0-9]+) at \(([0-9]+),([0-9]+)\).*/\1 \2 \3 \4/')
[ -n "${CROP_W:-}" ] || {
  echo "ios-record: could not read the crop from $raw" >&2
  exit 1
}

PICKED="$(ios_pick_device "${BLURT_SIM_DEVICE:-iPhone 18 Pro}")"
UDID="${PICKED%%	*}"
BUNDLE_ID=dev.alex.blurt.ios

echo "==> recording $name (two cycles)"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
movie="$OUT/$name.raw.mov"
rm -f "$movie"
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$movie" &
REC=$!
sleep 1
xcrun simctl launch "$UDID" "$BUNDLE_ID" -BlurtGallery "$LAYOUT" live "$THEME" -BlurtGalleryBare >/dev/null
LAUNCH_AT=1
sleep "$(python3 -c "print(2 * $CYCLE + 3)")"
kill -INT "$REC"
wait "$REC" 2>/dev/null || true

# Skip the launch and the first idle lead-in's start; one full cycle from
# the second idle so the loop begins and ends at rest.
start="$(python3 -c "print($LAUNCH_AT + 2.0 + $CYCLE)")"
ffmpeg -loglevel error -y -ss "$start" -t "$CYCLE" -i "$movie" \
  -vf "crop=$CROP_W:$CROP_H:$CROP_X:$CROP_Y,fps=60" -an -c:v libx264 -pix_fmt yuv420p -crf 18 \
  "$OUT/$name.mp4"
echo "loop: $OUT/$name.mp4 ($CYCLE s, ${CROP_W}×${CROP_H})"

if [ -n "$FRAMES" ]; then
  IFS=, read -ra FRAME_LIST <<<"$FRAMES"
  for t in "${FRAME_LIST[@]}"; do
    ffmpeg -loglevel error -y -ss "$t" -i "$OUT/$name.mp4" -frames:v 1 "$OUT/$name-${t}s.png"
    echo "frame: $OUT/$name-${t}s.png"
  done
fi
