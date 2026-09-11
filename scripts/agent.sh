#!/usr/bin/env bash
# Install or remove the background service.
#
# Installed, macOS starts the bridge at login and starts it again whenever it
# dies, so the page works whenever it is opened — including from the installed
# app icon, which is the case a terminal window cannot serve.
#
# Called by the two .command files people double-click. Installing is safe to
# repeat: doing it again after moving the folder repoints the service at the new
# path. The only thing it leaves outside this folder is one file in
# ~/Library/LaunchAgents, and "Remove background bridge.command" takes it back.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8770}"
APP_URL="http://localhost:${PORT}"
LABEL="com.airship.websdkinspector.bridge"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
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

# The folder path travels to launchd as XML text, and a folder is free to be
# called "Sales & Marketing".
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

write_plist() {
  local root_xml log_xml
  root_xml="$(xml_escape "$ROOT")"
  log_xml="$(xml_escape "$LOG")"

  # KeepAlive is conditional on purpose. Anything but a clean exit — a crash, a
  # kill, a port that was busy — brings the bridge back; a clean exit does not,
  # which is what makes "Remove" and Ctrl+C mean what they say.
  #
  # PATH is spelled out because launchd hands a job the bare minimum and reads
  # no shell profile: without the Homebrew directories, the iPhone side of the
  # bridge would report ios_webkit_debug_proxy as missing.
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
    <string>${root_xml}/scripts/start.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${root_xml}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PORT</key>
    <string>${PORT}</string>
    <key>BRIDGE_AGENT</key>
    <string>1</string>
    <key>BRIDGE_OPEN</key>
    <string>0</string>
    <key>BRIDGE_AUTO_INSTALL</key>
    <string>1</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>${log_xml}</string>
  <key>StandardErrorPath</key>
  <string>${log_xml}</string>
</dict>
</plist>
EOF
}

install_agent() {
  require_macos
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"

  bold "Airship Web SDK Inspector — background bridge"
  echo "Folder: $ROOT"
  echo ""

  write_plist

  # bootout first: a service already registered refuses to be registered twice,
  # and this is also the path that repoints a moved folder.
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    # Older macOS, and the deprecated spelling still works there.
    launchctl load -w "$PLIST" 2>/dev/null || {
      err "macOS refused to register the service."
      err "The log, if it says more, is at: $LOG"
      hold_window
      exit 1
    }
  fi
  launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl kickstart "$DOMAIN/$LABEL" 2>/dev/null || true

  # A first start can be slow: this may be the run that downloads Node and adb.
  echo "Starting it…"
  for _ in $(seq 1 120); do
    if bridge_is_up; then
      echo ""
      bold "Ready: $APP_URL"
      echo ""
      echo "The bridge now starts by itself when you log in, and starts again if"
      echo "it stops. There is no window to keep open: open the page or the"
      echo "installed app whenever you need it."
      echo ""
      echo "To undo this, double-click \"Remove background bridge.command\"."
      if command -v open >/dev/null 2>&1; then
        open "$APP_URL" >/dev/null 2>&1 || true
      fi
      hold_window
      return 0
    fi
    sleep 1
  done

  warn "The service is registered, but nothing is answering on port ${PORT} yet."
  echo ""
  echo "If the port is taken by a bridge you started by hand, close that window:"
  echo "the service takes over within a minute."
  echo ""
  echo "Otherwise the log says why: $LOG"
  hold_window
}

remove_agent() {
  require_macos

  bold "Airship Web SDK Inspector — removing the background bridge"
  echo ""

  if [[ ! -f "$PLIST" ]]; then
    echo "It was not installed. Nothing to remove."
    hold_window
    return 0
  fi

  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"

  echo "Removed. Nothing of the service is left on this machine."
  echo ""
  echo "The bridge is stopped. Double-click \"Start USB bridge.command\" when you"
  echo "need it, or install the service again."
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
