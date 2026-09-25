#!/bin/bash
# Shared by scripts/ios-*.sh: the one simulator signing recipe, and picking a
# simulator. Sourced, not run. Needs python3 (the CLT stub on a bare Mac).
#
# Ad hoc signing (identity "-") is what the simulator accepts without a team,
# and unlike CODE_SIGNING_ALLOWED=NO it embeds the entitlements, so the App
# Group the app and keyboard share works in the simulator too.
# shellcheck disable=SC2034 # used by the scripts that source this file
IOS_SIM_SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=)

# ios_pick_device NAME → prints "udid<TAB>name" for the available simulator
# called NAME on the newest iOS runtime, else for whichever iPhone this Mac
# (or CI runner) has; prints nothing if there is none.
ios_pick_device() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
wanted = sys.argv[1]
runtimes = json.load(sys.stdin)["devices"]
def version(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
found = []
for rt, devs in runtimes.items():
    if "iOS" not in rt:
        continue
    for d in devs:
        if d["name"].startswith("iPhone"):
            found.append((version(rt), d["name"] == wanted, d["name"], d["udid"]))
if not found:
    sys.exit(0)
found.sort(key=lambda f: (f[1], f[0]))
best = found[-1]
print(best[3] + "\t" + best[2])
' "$1"
}

# ios_wait_booted UDID → boots the simulator if needed and waits for it.
ios_wait_booted() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
}
