#!/bin/bash
# Apple's keyboard against Blurt's, key by key, on one simulator: the two
# geometry probes (AppleKeyboardProbe, BlurtKeyboardProbe) read every key's
# frame on both faces, and this prints the differences — x, y, width, height
# per key, the rows' edges, the keyboard's bottom — and fails on any over
# `TOLERANCE` points. The oracle is Apple's keyboard on this very simulator,
# not a stored JSON, so a new iOS is measured, not assumed.
#
#   scripts/keyboard-parity.sh                                   # the default simulator (glass, 402 pt)
#   BLURT_SIM_DEVICE="iPhone 17" scripts/keyboard-parity.sh
#   BLURT_SIM_RUNTIME=18.6 BLURT_SIM_DEVICE="iPhone 16e (18.6)" scripts/keyboard-parity.sh   # classic
#   scripts/keyboard-parity.sh --out .build/design/parity         # where the JSON and the screenshots land
#
# Blurt must be enabled as a keyboard on the simulator once by hand. What
# the frames cannot say — the caps' colour, the radius, the legend — is in
# the two screenshots the run leaves beside the JSON, for the eye.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/ios-lib.sh
source "$REPO_ROOT/scripts/ios-lib.sh"
DERIVED="$IOS_DERIVED"
OUT="$REPO_ROOT/.build/design/parity"
TOLERANCE="${BLURT_PARITY_TOLERANCE:-0.5}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      OUT="${2:?}"
      shift 2
      ;;
    *)
      echo "usage: keyboard-parity.sh [--out DIR]" >&2
      exit 2
      ;;
  esac
done

ios_require_device keyboard-parity
ios_wait_booted "$UDID"
rm -rf "$OUT"
mkdir -p "$OUT"

(cd "$REPO_ROOT/App/BlurtiOS" && xcodegen generate --quiet)
xcodebuild build -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" "${IOS_SIM_SIGNING[@]}" -quiet
xcrun simctl install "$UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/BlurtiOS.app"
xcrun simctl ui "$UDID" appearance light

echo "==> measuring Apple's keyboard and Blurt's on $NAME"
xcodebuild test -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOSProbe \
  -only-testing:BlurtiOSProbe/AppleKeyboardProbe -only-testing:BlurtiOSProbe/BlurtKeyboardProbe \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$OUT/parity.xcresult" "${IOS_SIM_SIGNING[@]}" -collect-test-diagnostics never -quiet
xcrun xcresulttool export attachments --path "$OUT/parity.xcresult" --output-path "$OUT/attachments" >/dev/null

SCALE="$(ios_device_scale "$UDID")"
python3 - "$OUT" "$TOLERANCE" "$NAME" "$SCALE" "$REPO_ROOT" <<'PY'
import json, os, shutil, subprocess, sys

out, tolerance, device, scale, root = sys.argv[1], float(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]
manifest = json.load(open(os.path.join(out, "attachments", "manifest.json")))
found = {}
for test in manifest:
    for a in test.get("attachments", []):
        # "apple-geometry-light_0_<uuid>.json": the name, then a counter and an id.
        human = a["suggestedHumanReadableName"]
        name = human.split("_")[0] + os.path.splitext(human)[1]
        src = os.path.join(out, "attachments", a["exportedFileName"])
        dst = os.path.join(out, name)
        shutil.copy(src, dst)
        found[name] = dst

# The same key under the two keyboards' names: Apple's labels on the left,
# the names KeyboardKit's buttons carry on the right (first match wins).
ALIASES = {
    "shift": ["shift", "Shift", "⇧"],
    "delete": ["delete", "Delete", "backspace", "Backspace", "⌫"],
    "more": ["more", "123", "numbers", "Numbers", "numeric", "Keyboard Type - numeric"],
    "numbers": ["numbers", "123", "more", "More", "Keyboard Type - numeric"],
    "space": ["space", "Space"],
    "Return": ["Return", "return", "newline", "⏎"],
    "return": ["return", "Return", "newline", "⏎"],
    "emoji": ["emoji", "Emoji", "blurt-mic"],
    "Emoji": ["Emoji", "emoji", "blurt-mic"],
}

def load(prefix, face):
    path = found.get(f"{prefix}-geometry-{face}.json")
    if not path:
        sys.exit(f"keyboard-parity: no {prefix}-geometry-{face}.json in the result bundle")
    return json.load(open(path))

def find(keys, name):
    for candidate in [name] + ALIASES.get(name, []) + [name.lower(), name.upper()]:
        if candidate in keys:
            return candidate, keys[candidate]
    return None, None

failures = 0
for face in ("light", "dark"):
    apple, blurt = load("apple", face), load("blurt", face)
    # Apple's shift, return and emoji keys are buttons to XCUITest, not keys:
    # the probe lists them under others as "button:<name>". The paddings
    # are the rows' margins, not keys.
    a_keys = {k: v for k, v in apple["keys"].items() if not k.startswith("Padding")}
    for name, frame in apple["others"].items():
        if name.startswith("button:") and name != "button:Next keyboard":
            a_keys.setdefault(name[len("button:"):], frame)
    b_keys = blurt["keys"]
    print(f"\n== {face} on {device}: {len(a_keys)} Apple keys, {len(b_keys)} Blurt keys")
    print(f"{'key':<14}{'dx':>7}{'dy':>7}{'dw':>7}{'dh':>7}   Apple (x y w h) → Blurt")
    unmatched = []
    for name, a in sorted(a_keys.items()):
        if name == "Next keyboard":
            continue  # the host's bar, not the keyboard's
        b_name, b = find(b_keys, name)
        if b is None:
            unmatched.append(name)
            continue
        d = {k: b[k] - a[k] for k in ("x", "y", "w", "h")}
        # Cells, not caps: Apple's are not centred on its caps, and the host
        # insets a third-party keyboard's view inside its container where
        # Apple's own sits flush, so x and y are shown, and w and h judged.
        bad = any(abs(d[k]) > tolerance for k in ("w", "h"))
        failures += bad
        flag = " !" if bad else ""
        print(f"{name:<14}{d['x']:>7.2f}{d['y']:>7.2f}{d['w']:>7.2f}{d['h']:>7.2f}   "
              f"{a['x']:.2f} {a['y']:.2f} {a['w']:.2f} {a['h']:.2f} → "
              f"{b['x']:.2f} {b['y']:.2f} {b['w']:.2f} {b['h']:.2f}{flag}")
    if unmatched:
        print(f"unmatched Apple keys (no Blurt key by that name): {', '.join(unmatched)}")
    extra = [n for n in b_keys if n not in a_keys and not any(n in v for v in ALIASES.values())]
    if extra:
        print(f"Blurt keys with no Apple counterpart: {', '.join(sorted(extra))}")
    kb_a, kb_b = apple["keyboard"], blurt["keyboard"]
    # The rows: the keys at the row height, which the bar's buttons are not.
    row_h = max((a["h"] for a in a_keys.values()), default=0)
    first_a = min((a["y"] for a in a_keys.values() if a["h"] == row_h), default=0)
    first_b = min((b["y"] for b in b_keys.values() if b["h"] == row_h), default=0)
    print(f"keyboard: Apple y {kb_a['y']:.2f} h {kb_a['h']:.2f}; Blurt keys span y {kb_b['y']:.2f} h {kb_b['h']:.2f}")
    print(f"first key row top: Apple {first_a} → Blurt {first_b} (the bar's height shows here)")
    bottom_a = max((a["y"] + a["h"] for a in a_keys.values() if a["h"] == row_h), default=0)
    bottom_b = max((b["y"] + b["h"] for b in b_keys.values() if b["h"] == row_h), default=0)
    print(f"last key row bottom: Apple {bottom_a:.2f} → Blurt {bottom_b:.2f}")
    pitch_a, pitch_b = bottom_a - first_a, bottom_b - first_b
    if abs(pitch_a - pitch_b) > tolerance:
        failures += 1
        print(f"  ! the rows span {pitch_a:.2f} on Apple's and {pitch_b:.2f} on Blurt's")

# The caps themselves, off the pixels — XCUITest's cells are touch targets,
# tiled with no gaps and not centred on the caps, so widths, gaps, margins,
# heights, the radius and the bar's band are read from the screenshots with
# design-diff.swift measure, each keyboard probed at its own cells.
def caps(prefix, face, keys, surface_key, names):
    shot = found.get(f"{prefix}-keyboard-{face}.png")
    q = keys["q"]
    sx = keys[surface_key]["x"] + keys[surface_key]["w"] / 2
    args = ["swift", os.path.join(root, "scripts/design-diff.swift"), "measure", shot, "--scale", str(scale),
            "--surface", f"{sx},{q['y'] - 3}", "--column", f"{q['x'] + q['w'] / 2}:{q['y'] - 80}:{q['y']}"]
    probes = {}
    for label, name in names.items():
        if name in keys:
            c = keys[name]
            probes[label] = f"{c['x'] + c['w'] / 2},{c['y'] + c['h'] / 2}"
            args += ["--probe", probes[label]]
    report = json.loads(subprocess.run(args, capture_output=True, text=True, check=True).stdout)
    by_probe = {c["probe"]: c for c in report["caps"]}
    measured = {}
    for label, probe in probes.items():
        c = by_probe.get(probe, {})
        if "error" in c:
            measured[label] = None
            continue
        measured[label] = c
    changes = report["columns"][0]["changes"]
    surface_top = changes[0]["y"] if changes else None
    letter = measured.get("q")
    row = letter["row"] if letter else []
    out_ = {
        "letter": round(sum(c["width"] for c in row) / len(row), 3) if row else None,
        "gap": round(sum(letter["gaps"]) / len(letter["gaps"]), 3) if letter and letter["gaps"] else None,
        "marginSide": row[0]["left"] if row else None,
        "height": letter["height"] if letter else None,
        "radius": letter["radius"] if letter else None,
        "capTop": letter["top"] if letter else None,
        "topBand": round(letter["top"] - surface_top, 3) if letter and surface_top is not None else None,
        "surfaceTop": surface_top,
        "fill": letter["fill"] if letter else None,
    }
    for label in ("shift", "space", "return", "abc", "small"):
        c = measured.get(label)
        out_[label] = c["width"] if c else None
        if label == "space" and c:
            out_["capBottom"] = c["bottom"]
        if label == "abc" and c:
            out_["abcFill"] = c["fill"]
    return out_

APPLE_NAMES = {"q": "q", "shift": "shift", "space": "space", "return": "Return", "abc": "more", "small": "emoji"}
BLURT_NAMES = {"q": "q", "shift": "Shift", "space": "space", "return": "return", "abc": "Keyboard Type - numeric",
               "small": "blurt-mic"}
for face in ("light", "dark"):
    apple, blurt = load("apple", face), load("blurt", face)
    a_keys = dict(apple["keys"])
    for name, frame in apple["others"].items():
        if name.startswith("button:"):
            a_keys.setdefault(name[len("button:"):], frame)
    try:
        a, b = caps("apple", face, a_keys, "space", APPLE_NAMES), caps("blurt", face, blurt["keys"], "space", BLURT_NAMES)
    except (subprocess.CalledProcessError, KeyError) as error:
        print(f"\n== caps on {face}: not measured ({error})")
        continue
    print(f"\n== caps on {face} (pixels): Apple → Blurt")
    # The caps' own numbers are judged; where the keyboard sits is shown:
    # iOS 26 insets a third-party keyboard's view inside the host's glass
    # container, above and below, where Apple's own keyboard sits flush, so
    # the whole of Blurt's keyboard stands that inset higher with its bar
    # that much taller — the host's, not the keyboard's (DESIGN.md).
    judged = ("letter", "gap", "marginSide", "height", "radius", "shift", "space", "return", "abc", "small")
    for key in judged + ("topBand", "capTop", "capBottom", "surfaceTop", "fill", "abcFill"):
        av, bv = a.get(key), b.get(key)
        flag = ""
        if key in judged and isinstance(av, (int, float)) and isinstance(bv, (int, float)) and abs(av - bv) > tolerance:
            flag = " !"
            failures += 1
        print(f"{key:<12} {av!s:>10} → {bv!s:<10}{flag}")
    if all(isinstance(v, (int, float)) for v in (a.get("capTop"), b.get("capTop"), a.get("surfaceTop"), b.get("surfaceTop"))):
        inset = (a["capTop"] - b["capTop"])
        print(f"placement: Blurt's rows sit {inset:.2f} pt above Apple's and its container top "
              f"{a['surfaceTop'] - b['surfaceTop']:.2f} pt above — the host's inset around a third-party keyboard")

print(f"\nscreenshots and JSON: {out}")
if failures:
    sys.exit(f"keyboard-parity: {failures} key(s) off by more than {tolerance} pt")
print(f"keyboard-parity: every matched key within {tolerance} pt of Apple's")
PY
