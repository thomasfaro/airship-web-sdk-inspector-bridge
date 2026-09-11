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
  # 64 is the stand-by below, which is a normal outcome and not a failure.
  if [[ "$code" -eq 0 || "$code" -eq 64 || "$code" -eq 130 ]]; then
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

# On the restart that follows an update, the banner has already been read.
if [[ "${BRIDGE_UPDATED:-0}" != "1" ]]; then
  bold "Airship Web SDK Inspector — USB bridge"
  echo "Folder: $ROOT"
  echo ""
fi

# A folder unzipped by a browser arrives quarantined. Clearing it cannot help the
# first launch — Gatekeeper has already run by the time we get here — but it is
# what makes every later double-click a plain double-click.
xattr -dr com.apple.quarantine . 2>/dev/null || true

# A restart started over from the top while the process it replaces was still
# letting go of the port. Nobody else is expected here, so waiting the moment out
# is what keeps the page's restart button to a few seconds.
if [[ "${BRIDGE_RESTARTING:-0}" == "1" ]]; then
  for _ in $(seq 1 20); do
    bridge_is_up || break
    sleep 0.5
  done
fi

if bridge_is_up; then
  READY=1
  # The background service is the one caller that must not shrug and leave: it
  # is meant to be holding this port. Whoever holds it wins for now, and exiting
  # short of success is what has launchd try again, so the service takes over
  # the moment the hand-started window is closed.
  if [[ "${BRIDGE_AGENT:-0}" == "1" ]]; then
    echo "Port ${PORT} is held by a bridge started by hand. Standing by."
    exit 64
  fi
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

# A file added at the top level of the folder cannot reach an install that
# already exists: an update only replaces what the version doing the updating
# knew about, and a version that predates a launcher has never heard of it. So
# the launchers travel inside scripts/ as well, and any that is missing from the
# folder is put back from there. Deleting one on purpose undoes itself, which is
# the price of every install ending up with the same folder.
if [[ -d "$ROOT/scripts/launchers" ]]; then
  for launcher in "$ROOT/scripts/launchers"/*.command; do
    [[ -e "$launcher" ]] || continue
    target="$ROOT/$(basename "$launcher")"
    if [[ ! -f "$target" ]]; then
      cp "$launcher" "$target" 2>/dev/null && chmod +x "$target" 2>/dev/null || true
    fi
  done
fi

# Updating replaces this very script, so the new one has to be the one that runs
# the rest. The guard keeps that to a single restart.
if [[ "${BRIDGE_UPDATED:-0}" != "1" ]]; then
  update_status=0
  node "$ROOT/scripts/update.mjs" || update_status=$?
  if [[ "$update_status" -eq 10 ]]; then
    echo "Restarting on the new version…"
    echo ""
    BRIDGE_UPDATED=1 exec bash "$ROOT/scripts/start.sh"
  fi
fi

# Registering the airship-bridge:// handler at every start, rather than only when
# the background service is installed, is what makes the page's "Start the bridge"
# button trustworthy: anyone who has ever started the bridge has the app that
# answers it. Idempotent, fast when there is nothing to do, and never fatal —
# failing to register a convenience is no reason not to start.
if [[ "$(uname -s)" == "Darwin" ]]; then
  bash "$ROOT/scripts/install-url-handler.sh" --quiet || true
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

# BRIDGE_MANAGED tells the server a launcher is watching it, which is what makes
# the page's "Update and restart" button possible.
start_server() {
  PORT="$PORT" BRIDGE_MANAGED=1 node "$ROOT/tools/bridge/server.js" &
  SERVER_PID=$!

  for _ in $(seq 1 40); do
    if bridge_is_up; then
      READY=1
      return 0
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}

# Three tries, because the one failure seen in practice is a race this loses by
# a fraction of a second: on a restart the port can still belong to the process
# being replaced, and a server that cannot bind exits immediately.
for attempt in 1 2 3; do
  if start_server; then
    break
  fi
  if [[ "$attempt" -lt 3 ]]; then
    sleep 1
  fi
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

server_status=0
wait "$SERVER_PID" || server_status=$?
SERVER_PID=""

# 75: the page's "Update and restart" button. The update itself happens at the
# top of this script, so starting over is the whole of it.
if [[ "$server_status" -eq 75 ]]; then
  echo ""
  bold "Updating and restarting…"
  echo ""
  # BRIDGE_UPDATED is cleared, not carried: it exists to keep a single startup
  # from updating twice, and exec keeps the environment, so leaving it set would
  # switch the updater off for the whole life of this launcher — one update ever,
  # then silence. This is a new startup and it gets to check again.
  BRIDGE_UPDATED=0 BRIDGE_RESTARTING=1 exec bash "$ROOT/scripts/start.sh"
fi

exit "$server_status"
