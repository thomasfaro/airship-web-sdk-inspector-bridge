#!/usr/bin/env bash
# Start the bridge with no terminal window, and return once it answers.
#
# This is what an airship-bridge:// link runs, so the bridge page can bring back
# the server it needs, and so the login agent can start it without reading a
# single file in the bridge folder.
#
#   --open    let the bridge open its page, the way a double-click does
#   --agent   identify a start requested by the background service
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# An applet's shell knows almost no PATH, and Homebrew is where adb usually is.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

PORT="${PORT:-8770}"
APP_URL="http://localhost:${PORT}"
ALIVE_URL="${APP_URL}/manifest.webmanifest"
LOG_FILE="$HOME/Library/Logs/airship-web-sdk-inspector-bridge.log"
OPEN_PAGE=0
FROM_AGENT=0

if [[ "${1:-}" == "--open" ]]; then
  OPEN_PAGE=1
elif [[ "${1:-}" == "--agent" ]]; then
  FROM_AGENT=1
fi

bridge_is_up() {
  curl -sf --max-time 3 "$ALIVE_URL" 2>/dev/null | grep -q "Airship"
}

if bridge_is_up; then
  if [[ "$OPEN_PAGE" -eq 1 ]] && command -v open >/dev/null 2>&1; then
    open "$APP_URL" >/dev/null 2>&1 || true
  fi
  exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")"

# nohup is what keeps the server alive after whoever asked for it — an applet, a
# link followed in a browser, a launchd tick — has gone. The launcher itself is
# unchanged: it installs what is missing, updates, and holds the port.
BRIDGE_OPEN="$OPEN_PAGE" BRIDGE_AGENT="$FROM_AGENT" BRIDGE_AUTO_INSTALL=1 \
  nohup bash "$ROOT/scripts/start.sh" \
  >>"$LOG_FILE" 2>&1 &

# Two seconds on a normal start; a first run has Node and adb to download.
for _ in $(seq 1 480); do
  if bridge_is_up; then
    exit 0
  fi
  sleep 0.25
done

echo "The bridge did not come up on port ${PORT}. Log: $LOG_FILE" >&2
exit 1
