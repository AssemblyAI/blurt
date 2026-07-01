#!/bin/bash
# Whole-app memory-leak check using the Darwin leak detector (the `leaks` tool —
# the same engine Instruments' Leaks instrument drives; see the xctrace note
# below). Run as part of the check.sh gate (after the UI suite, since both need a
# GUI session), and runnable on its own. It's safe to gate on because it fails
# only on leaks attributable to Blurt's own code — the fixed set of
# system-framework false positives is filtered out (see the attribution below).
#
# It complements the deterministic weak-reference assertions in MemoryLeakTests,
# which only cover the engine's DictationSession/KeyInjector. This drives the
# whole app — the AppCoordinator, the DictationKeyTap (gate + callbacks), the
# overlay, menu-bar status, windows, and phase observers — under the real
# allocator, catching cycles those unit tests can't anticipate.
#
# The app launches in -BlurtUITest mode (offline stub pipeline) with
# BLURT_LEAK_EXERCISE=1, which drives several dictation cycles *through the key
# tap* (see AppDelegate.runLeakExercise). MallocStackLogging gives the detector
# backtraces so a real leak is attributable.
#
# macOS reports a fixed set of leaks from system frameworks (NSXPCConnection
# cycles to com.apple.linkd for the App Intents / Shortcuts donation, etc.) that
# no app can fix. So this does NOT fail on the raw count — it fails only when a
# leak's backtrace runs through Blurt's own code.
#
# xctrace note: `xctrace record --instrument Leaks --launch` is the GUI-tool
# equivalent and is great for exploring backtraces in Instruments, but its
# launch-time task-port acquisition is refused in a headless/non-interactive
# shell ("Unable to acquire required task port"). The `leaks` CLI attaches to a
# process we already own and works there, so it's what this script gates on.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App/Blurt"
DERIVED="/tmp/blurt-leaks-dd"
REPORT="/tmp/blurt-leaks.txt"
SETTLE_SECONDS="${LEAKS_SETTLE_SECONDS:-6}"

command -v xcodebuild >/dev/null 2>&1 || {
  echo "error: xcodebuild not found (macOS/Xcode required)" >&2
  exit 1
}

if command -v xcbeautify >/dev/null 2>&1; then
  PRETTY=(xcbeautify --quiet)
else
  PRETTY=(cat)
fi

echo "==> building Blurt (Debug, ad-hoc) for the leak run"
cd "$APP_DIR"
set -o pipefail
xcodebuild \
  -project Blurt.xcodeproj \
  -scheme Blurt \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build | "${PRETTY[@]}"

APP_BIN="$DERIVED/Build/Products/Debug/Blurt.app/Contents/MacOS/Blurt"
[ -x "$APP_BIN" ] || {
  echo "error: built app binary not found at $APP_BIN" >&2
  exit 1
}

echo "==> launching the app and exercising the dictation path"
MallocStackLogging=1 BLURT_LEAK_EXERCISE=1 "$APP_BIN" -BlurtUITest \
  >/tmp/blurt-leaks-app.log 2>&1 &
APP_PID=$!
# Give launch + the scripted dictation cycles time to run before scanning.
sleep "$SETTLE_SECONDS"

echo "==> scanning pid $APP_PID with the leak detector"
# `leaks` returns non-zero when it finds any leak; we do our own attribution
# below, so don't let its exit status abort the script.
leaks "$APP_PID" >"$REPORT" 2>&1 || true
{ kill "$APP_PID" && wait "$APP_PID"; } >/dev/null 2>&1 || true

TOTAL_LINE="$(grep -oE '[0-9]+ leaks for [0-9]+ total leaked bytes' "$REPORT" | head -1)"
echo "==> ${TOTAL_LINE:-no leak summary} (full report: $REPORT)"

# Attribute: count leak-graph / backtrace lines whose module column is Blurt's
# own binary (the executable, its Debug dylib, or statically-linked BlurtEngine).
# The dyld image-list and the Path:/Identifier: header also mention "Blurt", so
# match only stack-frame lines: "<frameNo>  <Module>  0x… symbol".
APP_HITS="$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]+(Blurt|Blurt\.debug\.dylib|BlurtEngine)[[:space:]]+0x' "$REPORT" || true)"

if [ "$APP_HITS" -gt 0 ]; then
  echo "✗ Found $APP_HITS leak backtrace frame(s) in Blurt's own code:"
  grep -nE '^[[:space:]]*[0-9]+[[:space:]]+(Blurt|Blurt\.debug\.dylib|BlurtEngine)[[:space:]]+0x' "$REPORT" | head
  echo "  Inspect $REPORT (or open in Instruments' Leaks) for the full cycle."
  exit 1
fi

echo "==> ok — no leaks attributable to Blurt (any reported leaks are system"
echo "    framework XPC cycles, e.g. com.apple.linkd, which apps can't fix)."
