#!/usr/bin/env bash
# Install or remove the background service.
#
# Installed, macOS starts the bridge when you log in and checks on it every two
# minutes, so the page works whenever it is opened — including from the installed
# app icon, which is the case a terminal window cannot serve.
#
# What launchd runs is *not* a script in the bridge folder. It cannot be: macOS
# keeps Desktop, Documents, Downloads and iCloud Drive private from a launchd
# job, which has no window to ask permission through, and every read there comes
# back "Operation not permitted". So launchd runs a three-line script kept in
# ~/Library/Application Support, which asks the port a question and, if nothing
# answers, opens an airship-bridge:// link. The app behind that link is something
# macOS can name, and a named app is granted what /bin/bash is refused.
#
# Called by the two .command files people double-click. Installing is safe to
# repeat: doing it again after moving the folder repoints everything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8770}"
APP_URL="http://localhost:${PORT}"
LABEL="com.airship.websdkinspector.bridge"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SUPPORT_DIR="$HOME/Library/Application Support/Airship Web SDK Inspector"
LOGIN_SCRIPT="${SUPPORT_DIR}/login-start.sh"
LOG="$HOME/Library/Logs/airship-web-sdk-inspector-bridge.log"
DOMAIN="gui/$(id -u)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
err() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# A double-clicked script must never vanish before its message is read.
hold_window() {
  if [[ -t 0 ]]; then
    echo ""
    read -r -p "Press Return to close this window. " _ || true
  fi
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    err "The background service uses launchd, which is macOS only."
    err "On Linux, start the bridge with scripts/start.sh, or write a systemd user unit."
    hold_window
    exit 1
  fi
}

bridge_is_up() {
  curl -sf --max-time 4 "${APP_URL}/manifest.webmanifest" 2>/dev/null | grep -q "Airship"
}

write_login_script() {
  mkdir -p "$SUPPORT_DIR"
  # It lives out here, away from the bridge folder, because launchd could not
  # read it from Downloads — and it deliberately touches nothing in there:
  # asking a port a question and opening a link are allowed anywhere.
  #
  # The health check is what keeps this quiet. Opening the link launches an app,
  # which means an icon appearing in the Dock; doing that every two minutes for
  # a bridge that is already running would be its own kind of broken.
  cat >"$LOGIN_SCRIPT" <<LOGIN
#!/bin/bash
# Written by "Install background bridge" for ${ROOT}.
# Removed by "Remove background bridge.command".
if curl -sf --max-time 3 "${APP_URL}/manifest.webmanifest" 2>/dev/null | grep -q Airship; then
  exit 0
fi
exec /usr/bin/open "airship-bridge://background"
LOGIN
  chmod +x "$LOGIN_SCRIPT"
}

write_plist() {
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${LOGIN_SCRIPT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <!-- Nothing here stays running, so KeepAlive would only loop. This looks
       again instead: a bridge that stopped is back within two minutes. -->
  <key>StartInterval</key>
  <integer>120</integer>
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>/dev/null</string>
</dict>
</plist>
EOF

  if ! plutil -lint "$PLIST" >/dev/null 2>&1; then
    rm -f "$PLIST"
    err "Could not write a valid service definition."
    hold_window
    exit 1
  fi
}

install_agent() {
  require_macos
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"

  bold "Airship Web SDK Inspector — background bridge"
  echo "Folder: $ROOT"
  echo ""

  # The service starts the bridge by opening a link, so the app that answers it
  # comes first.
  if ! bash "$ROOT/scripts/install-url-handler.sh" --quiet; then
    err "Could not register the link the automatic start relies on."
    hold_window
    exit 1
  fi

  write_login_script
  write_plist

  # bootout first: a service already registered refuses to be registered twice,
  # and this is also the path that repoints a moved folder.
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    # Older macOS, where the deprecated spelling still works.
    launchctl load -w "$PLIST" 2>/dev/null || {
      err "macOS refused to register the service."
      hold_window
      exit 1
    }
  fi
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl kickstart "$DOMAIN/$LABEL" 2>/dev/null || true

  # Bootstrapping fires RunAtLoad, so the bridge is starting right now. A first
  # run may be the one that downloads Node and adb.
  echo "Starting it…"
  for _ in $(seq 1 180); do
    if bridge_is_up; then
      echo ""
      bold "Ready: $APP_URL"
      echo ""
      echo "The bridge starts when you log in, and comes back within two minutes"
      echo "if it ever stops. There is no window to keep open: open the page, or"
      echo "the installed app, whenever you need it."
      echo ""
      echo "\"Start Airship bridge\" is now in your Applications folder too — keep"
      echo "it in the Dock if you like starting things that way."
      echo ""
      echo "To undo all of this, double-click \"Remove background bridge.command\"."
      if command -v open >/dev/null 2>&1; then
        open "$APP_URL" >/dev/null 2>&1 || true
      fi
      hold_window
      return 0
    fi
    sleep 1
  done

  # A registered service that cannot start would try every two minutes for as
  # long as the machine is on. Leaving that behind is worse than not having
  # installed it, so it is taken back out.
  warn "The service did not come up on port ${PORT}, so it has been removed again."
  echo ""
  if [[ -f "$LOG" ]]; then
    echo "Last lines of the log ($LOG):"
    tail -n 15 "$LOG" 2>/dev/null || true
    echo ""
  fi
  if macos_asked_for_permission; then
    echo "macOS may be waiting for you to allow access to this folder. Look for a"
    echo "prompt, allow it, then double-click this file again."
    echo ""
  fi
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "\"Start USB bridge.command\" still works the way it always did."
  hold_window
}

# A denied folder shows up as this line, and it is the one failure worth naming.
macos_asked_for_permission() {
  tail -n 40 "$LOG" 2>/dev/null | grep -q "not permitted"
}

remove_agent() {
  require_macos

  bold "Airship Web SDK Inspector — removing the background bridge"
  echo ""

  if [[ ! -f "$PLIST" && ! -f "$LOGIN_SCRIPT" ]]; then
    echo "It was not installed. Nothing to remove."
    hold_window
    return 0
  fi

  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
  rm -f "$PLIST" "$LOGIN_SCRIPT"
  rmdir "$SUPPORT_DIR" 2>/dev/null || true

  echo "Removed: the bridge no longer starts by itself."
  echo ""
  # Deliberately kept: it is how the page starts the bridge when it finds it
  # stopped, and deleting an app is something people know how to do.
  echo "\"Start Airship bridge\" stays in your Applications folder, because the"
  echo "bridge page uses it to start the server. Drag it to the Trash if you want"
  echo "it gone as well."
  echo ""
  echo "The bridge that is running now keeps running. \"Start USB bridge.command\""
  echo "starts it next time."
  hold_window
}

case "${1:-}" in
  install) install_agent ;;
  remove) remove_agent ;;
  *)
    err "Usage: agent.sh install|remove"
    exit 2
    ;;
esac
