#!/bin/bash
# Measure the iPhone's own keyboard on the simulator and write what it found:
# the BlurtiOSProbe UI test launches the app on `-BlurtProbeField`, reads every
# key's frame off the system keyboard (both faces), and this turns the
# attachment into App/BlurtiOS/Design/apple-geometry.json — the table the
# keyboard's `key/*`, `row/gap` and `margin/*` tokens are pinned to
# (AppleGeometryTests) and the crop scripts/design-diff.swift measures the
# corner radius from.
#
#   scripts/apple-geometry.sh                 # iPhone 18 Pro, writes the JSON and prints the table
#   BLURT_SIM_DEVICE="iPhone 17" scripts/apple-geometry.sh --out /tmp/geometry.json
#
# Needs the on-screen keyboard: in Device Hub / Simulator, "Always simulate
# hardware keyboard" must be off, or no keyboard ever appears and the test fails.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"
DERIVED="$IOS_DERIVED"
OUT="$REPO_ROOT/App/BlurtiOS/Design/apple-geometry.json"
WORK="$REPO_ROOT/.build/design/probe"
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      OUT="${2:?}"
      shift 2
      ;;
    *)
      echo "usage: apple-geometry.sh [--out FILE.json]" >&2
      exit 2
      ;;
  esac
done

PICKED="$(ios_pick_device "${BLURT_SIM_DEVICE:-iPhone 18 Pro}")"
[ -n "$PICKED" ] || {
  echo "apple-geometry: no iPhone simulator available" >&2
  exit 1
}
UDID="${PICKED%%	*}"
NAME="${PICKED#*	}"
ios_wait_booted "$UDID"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> measuring the system keyboard on $NAME"
(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
RESULTS="$WORK/probe.xcresult"
xcodebuild test -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOSProbe \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULTS" "${IOS_SIM_SIGNING[@]}" -collect-test-diagnostics never -quiet
xcrun xcresulttool export attachments --path "$RESULTS" --output-path "$WORK/attachments" >/dev/null

# The attachments come out under generated names; the manifest maps them back.
# XCUITest reports touch cells, which tile a row with no gaps, so the caps
# themselves — widths, gaps, height, radius, the surface's top edge and the
# margins — are read off the light screenshot by design-diff.swift measure,
# with the probes placed inside the caps from the cells.
python3 - "$WORK/attachments" "$OUT" "$NAME" "$WORK" "$REPO_ROOT" <<'PY'
import json, os, shutil, subprocess, sys
from datetime import date
attachments, out, device, work, root = sys.argv[1:6]
manifest = json.load(open(os.path.join(attachments, "manifest.json")))
found = {}
for test in manifest:
    for a in test.get("attachments", []):
        found[a["suggestedHumanReadableName"]] = os.path.join(attachments, a["exportedFileName"])
faces, shots = {}, {}
for face in ("light", "dark"):
    name = next(k for k in found if k.startswith(f"apple-geometry-{face}"))
    faces[face] = json.load(open(found[name]))
    shot = next(k for k in found if k.startswith(f"apple-keyboard-{face}"))
    shots[face] = os.path.join(work, f"apple-keyboard-{face}.png")
    shutil.copy(found[shot], shots[face])

light = faces["light"]
keys, kb, win = light["keys"], light["keyboard"], light["window"]
def cell(name):
    if name not in keys:
        raise SystemExit(f"apple-geometry: the keyboard has no key called {name!r}; keys: {sorted(keys)}")
    return keys[name]
q, w, a, z, space, more = cell("q"), cell("w"), cell("a"), cell("z"), cell("space"), cell("more")
others = light.get("others", {})
shift = others.get("button:shift") or cell("shift")
ret = next((v for k, v in others.items() if k.lower().startswith("button:return")), None)
r3 = lambda v: round(v * 1000) / 1000

# Probes at each cell's centre: the cap's middle, which the scan reads
# through (a glyph is inside the cap; the edges are found past it).
def probe(c):
    return f'{c["x"] + c["w"] / 2},{c["y"] + c["h"] / 2}'
scale = 3  # the iPhone 18 Pro; the capture's pixels per point
def measure(face, probes, columns):
    args = ["swift", os.path.join(root, "scripts/design-diff.swift"), "measure", shots[face], "--scale", str(scale),
            "--surface", f'{space["x"] + space["w"] / 2},{q["y"] - 3}']
    for p in probes: args += ["--probe", p]
    for c in columns: args += ["--column", c]
    return json.loads(subprocess.run(args, capture_output=True, text=True, check=True).stdout)
row_l = {"w": keys["l"]["w"], "x": keys["l"]["x"], "y": keys["l"]["y"]}
# The surface's top edge is read down the keyboard's middle (its top corners
# are rounded); the l glyph's height down the column nearest its stroke.
mid = f'{win["w"] / 2}'
l_cx = keys["l"]["x"] + keys["l"]["w"] / 2
l_columns = [f'{l_cx + dx / 3}:{keys["l"]["y"]}:{keys["l"]["y"] + keys["l"]["h"]}' for dx in range(-4, 5)]
m = measure("light", [probe(q), probe(shift), probe(space), probe(ret) if ret else probe(more), probe(more)],
            [f'{mid}:{q["y"] - 80}:{q["y"]}'] + l_columns)
dark = measure("dark", [probe(q), probe(more)], [f'{mid}:{q["y"] - 80}:{q["y"]}'])
caps = {c["probe"]: c for c in m["caps"] if "error" not in c}
missing = [c for c in m["caps"] if "error" in c]
if missing:
    raise SystemExit(f"apple-geometry: probes missed a cap: {missing}")
letter, side, spacebar, returnkey, abc = (caps[probe(q)], caps[probe(shift)], caps[probe(space)],
                                          caps[probe(ret)] if ret else None, caps[probe(more)])
row1 = letter["row"]
surface_top = m["columns"][0]["changes"][0]["y"]
# Four changes down the column: cap top, glyph top, glyph bottom, cap bottom.
glyph_height = None
for column in m["columns"][1:]:
    changes = column["changes"]
    if len(changes) >= 4:
        glyph_height = changes[-2]["y"] - changes[1]["y"]
        break
cap = {
    "letter": r3(sum(c["width"] for c in row1) / len(row1)),
    "height": letter["height"],
    "gap": r3(sum(letter["gaps"]) / len(letter["gaps"])),
    "marginSide": row1[0]["left"],
    "marginRight": r3(win["w"] - row1[-1]["left"] - row1[-1]["width"]),
    "rowGap": r3(a["y"] - q["y"] - letter["height"]),
    "radius": letter["radius"],
    "side": r3((side["row"][0]["width"] + side["row"][-1]["width"]) / 2),
    "sideGap": side["gaps"][0],
    "abc": abc["width"],
    "space": spacebar["width"],
    "return": returnkey["width"] if returnkey else None,
    "topBand": r3(letter["top"] - surface_top),
    "bottomMargin": r3(kb["y"] + kb["h"] - letter["bottom"] - 3 * (a["y"] - q["y"])),
    "keyboardHeight": r3(kb["y"] + kb["h"] - surface_top),
    "systemBarBelow": r3(win["h"] - kb["y"] - kb["h"]),
}
geometry = {
    "device": device, "width": win["w"], "measured": date.today().isoformat(),
    "sources": {
        "cells": "XCUITest key frames (BlurtiOSProbe) — touch cells, no gaps",
        "caps": "pixel scan of the light screenshot (scripts/design-diff.swift measure)",
        "radius": "circle fitted to the top-left inset of the q cap over its first 12 pt (±0.25)",
        "legend": "the l glyph's height on the light face; the point size is an estimate (÷ 0.73, SF's ascender)",
    },
    "cell": {"letter": r3(q["w"]), "row": r3(a["y"] - q["y"]), "shift": r3(shift["w"]), "delete": r3(cell("delete")["w"]),
             "more": r3(more["w"]), "space": r3(space["w"]), "return": r3(ret["w"]) if ret else None,
             "firstRowTop": r3(q["y"]), "keyboardTop": r3(kb["y"]), "keyboardHeight": r3(kb["h"])},
    "cap": cap,
    "legend": {"lHeight": r3(glyph_height) if glyph_height else None,
               "pointSizeEstimate": r3(glyph_height / 0.73) if glyph_height else None},
    "colors": {"light": {"surface": m["surface"], "key": letter["fill"], "modifier": abc["fill"]},
               "dark": {"surface": dark["surface"], "key": dark["caps"][0]["fill"], "modifier": dark["caps"][1]["fill"]}},
    "darkFaceIdentical": all(
        abs(faces["dark"]["keys"].get(n, {}).get(kk, -1) - vv) < 0.01 for n, v in keys.items() for kk, vv in v.items()),
}
json.dump(geometry, open(out, "w"), indent=2, sort_keys=True)
open(out, "a").write("\n")
print(f"apple-geometry: {out}")
for k, v in cap.items():
    print(f"  cap.{k}: {v}")
print(f"  legend: {geometry['legend']}")
print(f"  colors: {geometry['colors']}")
print(f"  dark face identical: {geometry['darkFaceIdentical']}")
PY
echo "screenshots: $WORK/apple-keyboard-light.png, $WORK/apple-keyboard-dark.png"
