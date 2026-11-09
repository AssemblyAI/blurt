#!/bin/bash
# Shared by scripts/ios-*.sh: the one simulator signing recipe, and picking a
# simulator. Sourced, not run. Needs python3 (the CLT stub on a bare Mac).
#
# Ad hoc signing (identity "-") is what the simulator accepts without a team,
# and unlike CODE_SIGNING_ALLOWED=NO it embeds the entitlements, so the App
# Group the app and keyboard share works in the simulator too.
# shellcheck disable=SC2034 # used by the scripts that source this file
IOS_SIM_SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)

# The iPhone build's derived data, shared so each script's build reuses the
# last one's (ios-check.sh's probe build relies on it). Needs REPO_ROOT set by
# the sourcing script; BLURT_DERIVED_DATA moves it (CI puts it in RUNNER_TEMP).
# shellcheck disable=SC2034 # used by the scripts that source this file
IOS_DERIVED="${BLURT_DERIVED_DATA:-$REPO_ROOT/.build/ios-sim}"

# ios_pick_device NAME → prints "udid<TAB>name" for the available simulator
# called NAME on the newest iOS runtime, else for whichever iPhone this Mac
# (or CI runner) has; prints nothing if there is none. BLURT_SIM_RUNTIME
# ("18.6", or "18" for any 18.x) keeps the pick to simulators on that
# runtime — the iOS 18 leg of the keyboard flows, where the keyboard draws
# its classic profile.
ios_pick_device() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
wanted, runtime = sys.argv[1], sys.argv[2]
runtimes = json.load(sys.stdin)["devices"]
def version(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
def on_runtime(rt):
    if not runtime:
        return True
    return ".".join(str(n) for n in version(rt)).startswith(runtime) or str(version(rt)[0]) == runtime
found = []
for rt, devs in runtimes.items():
    if "iOS" not in rt or not on_runtime(rt):
        continue
    for d in devs:
        if d["name"].startswith("iPhone"):
            found.append((version(rt), d["name"] == wanted, d["name"], d["udid"]))
if not found:
    sys.exit(0)
found.sort(key=lambda f: (f[1], f[0]))
best = found[-1]
print(best[3] + "\t" + best[2])
' "$1" "${BLURT_SIM_RUNTIME:-}"
}

# The simulator every script picks unless BLURT_SIM_DEVICE names another.
IOS_DEFAULT_DEVICE="iPhone 18 Pro"

# ios_require_device SCRIPT → sets UDID and NAME to the simulator to use
# (BLURT_SIM_DEVICE, else IOS_DEFAULT_DEVICE, else any iPhone), or exits
# with an error naming SCRIPT when this Mac has none.
ios_require_device() {
  local picked
  picked="$(ios_pick_device "${BLURT_SIM_DEVICE:-$IOS_DEFAULT_DEVICE}")"
  if [ -z "$picked" ]; then
    echo "$1: no iPhone simulator available (xcrun simctl list devices${BLURT_SIM_RUNTIME:+; BLURT_SIM_RUNTIME=$BLURT_SIM_RUNTIME})" >&2
    exit 1
  fi
  # shellcheck disable=SC2034 # used by the scripts that source this file
  UDID="${picked%%	*}"
  # shellcheck disable=SC2034 # used by the scripts that source this file
  NAME="${picked#*	}"
}

# ios_wait_booted UDID → boots the simulator if needed and waits for it.
ios_wait_booted() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
}

# ios_device_scale UDID → prints the simulator's screen scale (2 or 3): the
# pixels per point a screenshot of it has, read from its device type's
# profile (the iPhone SE is 2×, every Face ID phone 3×).
ios_device_scale() {
  xcrun simctl list devices -j | python3 -c '
import json, subprocess, sys
udid = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
kind = next((d["deviceTypeIdentifier"] for devs in devices.values() for d in devs if d["udid"] == udid), None)
if kind is None:
    sys.exit(f"ios_device_scale: no simulator {udid}")
types = json.loads(subprocess.run(["xcrun", "simctl", "list", "devicetypes", "-j"], capture_output=True, text=True,
                                  check=True).stdout)["devicetypes"]
bundle = next(t["bundlePath"] for t in types if t["identifier"] == kind)
scale = subprocess.run(["plutil", "-extract", "capabilities.ArtworkTraits.ArtworkDeviceScaleFactor", "raw",
                        bundle + "/Contents/Resources/capabilities.plist"], capture_output=True, text=True,
                       check=True).stdout.strip()
print(int(float(scale)))
' "$1"
}

# ios_device_runtime_id UDID → prints the simulator's runtime identifier
# (com.apple.CoreSimulator.SimRuntime.iOS-27-0).
ios_device_runtime_id() {
  xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1]
for rt, devs in json.load(sys.stdin)["devices"].items():
    if any(d["udid"] == udid for d in devs):
        print(rt)
        break
' "$1"
}

# ios_device_runtime UDID → prints the iOS version the simulator runs ("27.0").
ios_device_runtime() {
  ios_device_runtime_id "$1" | python3 -c '
import re, sys
rt = sys.stdin.read().strip()
m = re.search(r"iOS-(\d+)-(\d+)", rt)
print(f"{m.group(1)}.{m.group(2)}" if m else rt)
'
}
