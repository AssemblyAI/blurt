#!/bin/bash
# Serve the static site/ directory locally for development.
#
# Usage:
#   scripts/serve-site.sh [port]              serve at http://localhost:<port> (default 8000)
#   scripts/serve-site.sh --simulator [port]  also open the page in the iOS Simulator's
#                                              mobile Safari (the simulator shares the Mac's
#                                              localhost). Requires Xcode. Alias: -s

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIMULATOR=0
PORT=8000

for arg in "$@"; do
  case "$arg" in
    --simulator | -s) SIMULATOR=1 ;;
    *[!0-9]*)
      echo "error: unrecognized argument '$arg'" >&2
      exit 1
      ;;
    *) PORT="$arg" ;;
  esac
done

URL="http://localhost:$PORT"
cd "$REPO_ROOT/site"

if [ "$SIMULATOR" -eq 0 ]; then
  echo "==> Serving $REPO_ROOT/site at $URL"
  echo "    Press Ctrl-C to stop."
  exec python3 -m http.server "$PORT"
fi

command -v xcrun >/dev/null 2>&1 || {
  echo "error: --simulator needs Xcode (xcrun not found)." >&2
  exit 1
}

# Serve in the background so we can drive the simulator, then hand control back to
# the server (Ctrl-C tears both down via the trap).
python3 -m http.server "$PORT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM

echo "==> Serving $REPO_ROOT/site at $URL"
echo "==> Booting the iOS Simulator…"
open -a Simulator

# Wait for a device to finish booting before handing it the URL.
for _ in $(seq 1 60); do
  if xcrun simctl list devices booted 2>/dev/null | grep -q "(Booted)"; then
    break
  fi
  sleep 1
done

if xcrun simctl list devices booted 2>/dev/null | grep -q "(Booted)"; then
  echo "==> Opening $URL in mobile Safari"
  xcrun simctl openurl booted "$URL"
else
  echo "warning: no simulator booted in time; open $URL in the simulator manually." >&2
fi

echo "    Press Ctrl-C to stop."
wait "$SERVER_PID"
