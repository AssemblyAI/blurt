#!/bin/bash
# Blurt on a real iPhone, from the terminal: install, launch, kill, and read
# the phone's logs — no Xcode window, no debugger. The device gate every
# capture change runs before it lands (App/BlurtiOS/README.md › Testing on a
# phone): preflight → install → launch → dictate → pull → syslog --negative.
#
#   scripts/ios-device.sh preflight                 # the phone, Developer Mode, and the checklist
#   scripts/ios-device.sh install                   # xcodegen, build for the phone, install
#   scripts/ios-device.sh launch [args…]            # launch Blurt (default args: -BlurtDeveloperMode YES)
#   scripts/ios-device.sh kill blurt|keyboard       # SIGKILL the app or the keyboard extension
#   scripts/ios-device.sh pull DIR [--syslog] [--last 15m]
#                                                   # Blurt's own logs → DIR/Logs; with --syslog the
#                                                   # phone's system log too → DIR/device.logarchive
#   scripts/ios-device.sh syslog ARCHIVE [--last 15m] [--negative]
#                                                   # read an archive: Blurt's lines, or assert the
#                                                   # negative predicate (no background-start refusal)
#   scripts/ios-device.sh flows | check             # not yet: DeviceFlows lands with the device gate
#
#   BLURT_DEVICE=<udid or name>   another phone (default: Neil's iPhone 13)
#   BLURT_TEAM=<team id>          another team (default: AssemblyAI INC.)
#   DEVICECTL_CHILD_BLURT_DEBUG_API_KEY=<key> scripts/ios-device.sh launch
#                                 a Debug build takes the key from its environment, so a
#                                 fresh install can listen without typing one
#
# The phone: plugged in, unlocked, "Trust This Computer" accepted, Developer
# Mode on (Settings › Privacy & Security). `install` signs for development on
# the team and replaces whatever Blurt is on the phone (same bundle id); the
# first run registers the phone on the team. The app's launch arguments go
# after `--` on the devicectl line: `-BlurtDeveloperMode` reads as devicectl's
# own `-t` otherwise.
#
# `pull --syslog` runs `log collect --device-udid`, which needs root, so macOS
# puts up its administrator-password dialog (osascript's `with administrator
# privileges`) — the one way to run it from a script without `sudo -S` and a
# password on the terminal — and the archive is handed back to you (`chown`).
# `syslog`'s `--last` counts back from the archive's end, not from now.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-lib.sh
source "$REPO_ROOT/scripts/release-lib.sh"

TEAM="${BLURT_TEAM:-B2VQF7Q2QY}"
DEVICE="${BLURT_DEVICE:-00008110-000968A21446801E}"
# PRODUCT_BUNDLE_IDENTIFIER in App/BlurtiOS/project.yml.
BUNDLE_ID=com.assemblyai.blurt.iphone
# One derived-data directory per checkout, so two worktrees' phone builds never
# share (or poison) each other's.
DD="${TMPDIR:-/tmp}/blurt-device-dd-$(printf %s "$REPO_ROOT" | shasum | cut -c1-8)"
APP="$DD/Build/Products/Debug-iphoneos/BlurtiOS.app"

# What a run reads back from the phone's system log: Blurt's own lines, the
# system daemons' lines about it, and the two spellings of iOS refusing a
# recording started from the background (`'!rec'` is 561145187).
BLURT_PREDICATE='subsystem == "com.assemblyai.blurt.iphone"'
BLURT_PREDICATE+=' OR process == "BlurtiOS" OR process == "BlurtKeyboard"'
BLURT_PREDICATE+=' OR (eventMessage CONTAINS "com.assemblyai.blurt"'
BLURT_PREDICATE+=' AND (process == "SpringBoard" OR process == "runningboardd" OR process == "audiomxd"))'
BLURT_PREDICATE+=' OR eventMessage CONTAINS "start recording in the background"'
BLURT_PREDICATE+=' OR eventMessage CONTAINS "561145187"'
# The refusal every gate run asserts is absent, in its three spellings.
NEGATIVE_PREDICATE='eventMessage CONTAINS "start recording in the background"'
NEGATIVE_PREDICATE+=' OR eventMessage CONTAINS "561145187" OR eventMessage CONTAINS "!rec"'
# A refusal counts when the line names Blurt: its bundle id, or its own process.
NAMES_BLURT='com\.assemblyai\.blurt|BlurtiOS\[|BlurtKeyboard\['
# What `syslog` drops: the lines every process emits all day.
NOISE='systemAnimationFence|Hit the server|Received state update|activating connection'

usage() {
  cat >&2 <<'EOF'
usage: ios-device.sh preflight
       ios-device.sh install
       ios-device.sh launch [args…]                   (default: -BlurtDeveloperMode YES)
       ios-device.sh kill blurt|keyboard
       ios-device.sh pull DIR [--syslog] [--last 15m]  (--syslog asks for an administrator password:
                                                        log collect needs root)
       ios-device.sh syslog ARCHIVE [--last 15m] [--negative]
       ios-device.sh flows | check                     (not yet: DeviceFlows lands with the device gate)
EOF
  exit 2
}

TMP="$(mktemp -d -t blurt-device)"
trap 'rm -rf "$TMP"' EXIT

# resolve_device → sets UDID and NAME from `devicectl list devices` for the
# phone BLURT_DEVICE names (by UDID, name, serial or CoreDevice id), or exits
# naming it. Reads the JSON, never the table.
resolve_device() {
  local picked
  xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null
  picked="$(python3 -c '
import json, sys
wanted = sys.argv[1]
for d in json.load(open(sys.argv[2]))["result"]["devices"]:
    p = d.get("properties", {})
    hw, st = p.get("hardware", {}), p.get("state", {})
    if wanted in {hw.get("udid"), hw.get("serialNumber"), st.get("name"), d.get("identifier")}:
        print(hw.get("udid", ""), st.get("name", ""), sep="\t")
        break
' "$DEVICE" "$TMP/devices.json")"
  if [ -z "$picked" ]; then
    echo "ios-device: no device '$DEVICE' in xcrun devicectl list devices — plug the phone in, unlock it, trust this Mac" >&2
    exit 1
  fi
  UDID="${picked%%	*}"
  NAME="${picked#*	}"
}

# --last takes what `log collect` and `log show` take: <num>[s|m|h|d].
require_span() {
  [[ "$1" =~ ^[0-9]+[smhd]$ ]] || {
    echo "ios-device: --last takes <num>[s|m|h|d], not '$1'" >&2
    exit 2
  }
}

# applescript_string TEXT → TEXT as the inside of an AppleScript string literal.
applescript_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

preflight() {
  local missing=() status lock installed
  require_tools --hint='full Xcode, not the Command Line Tools' xcodebuild xcodegen
  resolve_device
  echo "phone: $NAME ($UDID)"

  # "available" is the list's State column — the JSON carries no such field —
  # so the one assertion that needs it filters on the column, and reads the
  # filtered JSON back (an unplugged or untrusted phone lists as unavailable).
  xcrun devicectl list devices --filter "Identifier = '$UDID' AND State BEGINSWITH 'available'" \
    --json-output "$TMP/available.json" >/dev/null
  if python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["result"]["devices"] else 1)' \
    "$TMP/available.json"; then
    echo "state: available"
  else
    echo "state: not available"
    missing+=("the phone is not available: plug it in, unlock it, and trust this Mac")
  fi

  if xcrun devicectl device info details --device "$UDID" --json-output "$TMP/details.json" \
    >/dev/null 2>"$TMP/details.err"; then
    status="$(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))["result"]
status = r.get("deviceProperties", {}).get("developerModeStatus")
if status is None:
    status = next(iter(r.get("properties", {}).get("state", {}).get("developerModeStatus", {})), "unknown")
print(status)
' "$TMP/details.json")"
    echo "Developer Mode: $status"
    [ "$status" = "enabled" ] \
      || missing+=("Developer Mode is $status: Settings › Privacy & Security › Developer Mode, then restart the phone")
  else
    cat "$TMP/details.err" >&2
    missing+=("devicectl could not read the phone (device info details failed)")
  fi

  if xcrun devicectl device info lockState --device "$UDID" --json-output "$TMP/lock.json" >/dev/null 2>&1; then
    lock="$(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))["result"]
print("unlocked since boot" if r.get("unlockedSinceBoot") else "never unlocked since boot")
' "$TMP/lock.json")"
    echo "lock: $lock"
    case "$lock" in
      never*) missing+=("the phone has not been unlocked since it booted: unlock it once") ;;
    esac
  fi

  if xcrun devicectl device info apps --device "$UDID" --bundle-id "$BUNDLE_ID" --json-output "$TMP/apps.json" \
    >/dev/null 2>&1; then
    installed="$(python3 -c '
import json, sys
for a in json.load(open(sys.argv[1]))["result"]["apps"]:
    print(a.get("version", "?"), "(" + a.get("bundleVersion", "?") + ")")
' "$TMP/apps.json")"
    echo "Blurt installed: ${installed:-no (run install)}"
  fi

  cat <<'EOF'
Check on the phone (nothing here can see these):
  - Settings › Developer › Enable UI Automation: on (the flows need it)
  - Settings › Apps › Blurt › Keyboards: Blurt on, Allow Full Access on
  - Blurt: an API key pasted (or DEVICECTL_CHILD_BLURT_DEBUG_API_KEY on a Debug launch)
EOF

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ios-device: preflight failed:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
  fi
  echo "ios-device: preflight ok — $NAME is ready for install and launch"
}

install_app() {
  local branch
  require_tools --hint='full Xcode, not the Command Line Tools' xcodebuild xcodegen
  resolve_device
  branch="$(git -C "$REPO_ROOT" branch --show-current)"
  echo "build: $(git -C "$REPO_ROOT" rev-parse --short HEAD)${branch:+ on $branch} → $NAME, team $TEAM"
  echo "==> generate + build (Debug, $DD)"
  (cd "$REPO_ROOT/App/BlurtiOS" && BLURT_TEAM="$TEAM" xcodegen generate --quiet)
  xcodebuild build -project "$REPO_ROOT/App/BlurtiOS/BlurtiOS.xcodeproj" -scheme BlurtiOS -configuration Debug \
    -destination "id=$UDID" -derivedDataPath "$DD" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet
  echo "==> install"
  xcrun devicectl device install app --device "$UDID" "$APP"
}

launch_app() {
  resolve_device
  [ $# -gt 0 ] || set -- -BlurtDeveloperMode YES
  echo "launch: $BUNDLE_ID $* on $NAME"
  # `--` keeps devicectl from reading the app's `-Blurt…` arguments as its own.
  if ! xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE_ID" -- "$@" \
    2>&1 | tee "$TMP/launch.log"; then
    if grep -qi 'locked' "$TMP/launch.log"; then
      echo "ios-device: the phone is locked — unlock the phone and run launch again" >&2
    fi
    exit 1
  fi
}

kill_process() {
  local suffix pid
  case "${1:-}" in
    blurt) suffix="BlurtiOS.app/BlurtiOS" ;;
    keyboard) suffix="BlurtKeyboard.appex/BlurtKeyboard" ;;
    *) usage ;;
  esac
  resolve_device
  xcrun devicectl device info processes --device "$UDID" --json-output "$TMP/processes.json" >/dev/null
  pid="$(python3 -c '
import json, sys
for p in json.load(open(sys.argv[2]))["result"]["runningProcesses"]:
    if p.get("executable", "").endswith("/" + sys.argv[1]):
        print(p["processIdentifier"])
        break
' "$suffix" "$TMP/processes.json")"
  if [ -z "$pid" ]; then
    echo "ios-device: $1 is not running on $NAME" >&2
    exit 1
  fi
  echo "kill: $1 (pid $pid) on $NAME"
  xcrun devicectl device process signal --device "$UDID" --pid "$pid" --signal SIGKILL
}

pull_logs() {
  local dir syslog=0 last=15m archive
  [ $# -ge 1 ] || usage
  dir="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --syslog)
        syslog=1
        shift
        ;;
      --last)
        last="${2:?}"
        shift 2
        ;;
      *) usage ;;
    esac
  done
  require_span "$last"
  resolve_device
  mkdir -p "$dir"
  echo "==> Blurt's logs (Library/Logs/Blurt) → $dir/Logs"
  if ! xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source Library/Logs/Blurt --destination "$dir/Logs" \
    2>&1 | tee "$TMP/copy.log"; then
    # CoreDevice error 7000: the path is not there. Nothing logged yet (the
    # engine writes its logs in developer mode) is not a failed pull.
    grep -q 'Failed to retrieve the file node' "$TMP/copy.log" || exit 1
    echo "ios-device: no Library/Logs/Blurt on the phone yet — Blurt has not logged (developer mode off, or not launched)"
  fi
  [ "$syslog" -eq 1 ] || return 0
  archive="$dir/device.logarchive"
  rm -rf "$archive"
  echo "==> the phone's system log, last $last → $archive"
  echo "    log collect needs root: macOS asks for an administrator password"
  # The archive is root's when `log collect` is done; `chown` hands it back.
  local script
  script="do shell script \"/usr/bin/log collect --device-udid $UDID --last $last --output \""
  script+=" & quoted form of \"$(applescript_string "$archive")\""
  script+=" & \" && chown -R $(id -u) \" & quoted form of \"$(applescript_string "$archive")\""
  script+=" with administrator privileges"
  osascript -e "$script"
  echo "archive: $archive"
}

show_syslog() {
  local archive last=15m negative=0 hits
  [ $# -ge 1 ] || usage
  archive="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --negative)
        negative=1
        shift
        ;;
      --last)
        last="${2:?}"
        shift 2
        ;;
      *) usage ;;
    esac
  done
  require_span "$last"
  if [ ! -d "$archive" ]; then
    echo "ios-device: no log archive at $archive (pull DIR --syslog writes DIR/device.logarchive)" >&2
    exit 1
  fi
  if [ "$negative" -eq 1 ]; then
    hits="$(/usr/bin/log show --archive "$archive" --last "$last" --info --debug --style compact \
      --predicate "$NEGATIVE_PREDICATE" | { grep -E "$NAMES_BLURT" || true; })"
    if [ -n "$hits" ]; then
      printf '%s\n' "$hits"
      echo "error: iOS refused a recording started from the background for Blurt (last $last of $archive)" >&2
      exit 1
    fi
    echo "ios-device: negative predicate holds — no background-start refusal names Blurt in the last $last"
    return 0
  fi
  /usr/bin/log show --archive "$archive" --last "$last" --info --debug --style compact \
    --predicate "$BLURT_PREDICATE" | { grep -v -E "$NOISE" || true; }
}

[ $# -gt 0 ] || usage
COMMAND="$1"
shift
case "$COMMAND" in
  preflight) preflight ;;
  install) install_app ;;
  launch) launch_app "$@" ;;
  kill) kill_process "$@" ;;
  pull) pull_logs "$@" ;;
  syslog) show_syslog "$@" ;;
  flows | check)
    echo "ios-device: not yet: DeviceFlows lands with the device gate" >&2
    exit 2
    ;;
  *) usage ;;
esac
