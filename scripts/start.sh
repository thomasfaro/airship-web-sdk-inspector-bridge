#!/usr/bin/env bash
# One-click launcher: install what is missing, update, start the bridge, open the
# page. Called by "Start USB bridge.command", which is what people double-click.
#
# Nothing here needs a terminal, an administrator password, or a package manager.
# Node and adb are fetched into .node/ and .adb/ inside this folder, and deleting
# the folder undoes everything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-8770}"
APP_URL="http://localhost:${PORT}"
# Not /api/status: that one scans the cable for phones and can take seconds. The
# manifest is a static file, and naming us in its body tells our bridge apart
# from whatever else might be sitting on the port.
ALIVE_URL="${APP_URL}/manifest.webmanifest"
READY=0

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
err() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# A double-clicked launcher must never vanish before the message is read.
hold_window() {
  if [[ -t 0 ]]; then
    echo ""
    read -r -p "Press Return to close this window. " _ || true
  fi
}

bridge_is_up() {
  curl -sf --max-time 4 "$ALIVE_URL" 2>/dev/null | grep -q "Airship"
}

# Only used when the bridge is already up; on a normal start the server opens the
# page itself, and prefers the installed app to a tab. BRIDGE_OPEN=0 means the
# same here as it does there: leave my browser alone.
open_page() {
  if [[ "${BRIDGE_OPEN:-1}" == "0" ]]; then
    return
  fi
  if command -v open >/dev/null 2>&1; then
    open "$APP_URL" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$APP_URL" >/dev/null 2>&1 || true
  else
    echo "Open $APP_URL in your browser."
  fi
}

on_exit() {
  local code=$?
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "$code" -eq 0 || "$code" -eq 130 ]]; then
    return
  fi
  err ""
  if [[ "$READY" -eq 1 ]]; then
    err "The bridge stopped unexpectedly (exit code $code)."
  else
    err "Startup failed (exit code $code)."
  fi
  hold_window
}
trap on_exit EXIT
trap 'exit 130' INT TERM

bold "Airship Web SDK Inspector — USB bridge"
echo "Folder: $ROOT"
echo ""

# A folder unzipped by a browser arrives quarantined. Clearing it cannot help the
# first launch — Gatekeeper has already run by the time we get here — but it is
# what makes every later double-click a plain double-click.
xattr -dr com.apple.quarantine . 2>/dev/null || true

if bridge_is_up; then
  READY=1
  bold "Already running — reopening $APP_URL"
  open_page
  exit 0
fi

# Finds Node, or offers to install a private copy in .node/ when there is none.
# shellcheck source=scripts/ensure-node.sh
. "$ROOT/scripts/ensure-node.sh"
if ! ensure_node_available "$ROOT"; then
  hold_window
  exit 1
fi

# Updating replaces this very script, so the new one has to be the one that runs
# the rest. The guard keeps that to a single restart.
if [[ "${BRIDGE_UPDATED:-0}" != "1" ]]; then
  update_status=0
  node "$ROOT/scripts/update.mjs" || update_status=$?
  if [[ "$update_status" -eq 10 ]]; then
    echo ""
    BRIDGE_UPDATED=1 exec bash "$ROOT/scripts/start.sh"
  fi
fi

# adb is the cable. The bridge can start without it — the page then says so — but
# it would have nothing to talk to, so this is worth one question.
adb_dir=""
adb_status=0
adb_dir="$(node "$ROOT/scripts/ensure-adb.mjs" --probe)" || adb_status=$?

if [[ "$adb_status" -ne 0 ]]; then
  reply=""
  echo "Android debugging tools (adb) were not found on this machine."
  echo ""
  echo "This launcher can install its own private copy in:"
  echo "  ${ROOT}/.adb"
  echo ""
  echo "About 16 MB from Google, no administrator password, and deleting that"
  echo "folder removes it completely."
  echo ""
  if [[ "${BRIDGE_AUTO_INSTALL:-0}" == "1" ]]; then
    reply="y"
  elif [[ -t 0 ]]; then
    read -r -p "Install it now? [Y/n] " reply || reply="n"
  else
    reply="n"
  fi

  case "${reply:-y}" in
    y | Y | yes | YES | Yes)
      adb_status=0
      adb_dir="$(node "$ROOT/scripts/ensure-adb.mjs" --install)" || adb_status=$?
      ;;
    *) adb_status=1 ;;
  esac
fi

if [[ "$adb_status" -eq 0 && -n "$adb_dir" ]]; then
  PATH="${adb_dir}:$PATH"
  export PATH
else
  warn "Continuing without adb: the page will open, but no Android phone can be read."
  echo ""
fi

echo "Starting on port ${PORT}…"
echo ""
PORT="$PORT" node "$ROOT/tools/bridge/server.js" &
SERVER_PID=$!

for _ in $(seq 1 40); do
  if bridge_is_up; then
    READY=1
    break
  fi
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.25
done

if [[ "$READY" -ne 1 ]]; then
  err "The bridge did not come up on port ${PORT}."
  err "Something else may be using that port; try PORT=8771 in a terminal."
  exit 1
fi

echo ""
bold "Ready: $APP_URL"
echo ""
echo "On the phone: Developer options → USB debugging, cable plugged in, prompt"
echo "accepted, screen unlocked, Chrome open on the page you want to read."
echo ""
echo "Keep this window open while you use the bridge — it is the bridge."
echo "Press Ctrl+C, or close this window, to stop it."
echo ""

wait "$SERVER_PID"
