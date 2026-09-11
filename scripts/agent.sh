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

# Desktop, Documents, Downloads and iCloud Drive are protected by macOS privacy
# rules. A double-clicked launcher reads them because Terminal has permission; a
# background service has no window to ask through, so every read fails with
# "Operation not permitted" and the service restarts forever. Nothing can be
# granted from a script, so the folder has to sit outside those four.
protected_location() {
  case "$ROOT/" in
    "$HOME/Desktop/"* | "$HOME/Documents/"* | "$HOME/Downloads/"* | "$HOME/Library/Mobile Documents/"*)
      return 0
      ;;
  esac
  return 1
}

move_out_of_protected_location() {
  local target="$HOME/$(basename "$ROOT")"
  local reply=""

  warn "macOS will not let a background service read this folder."
  echo ""
  echo "Desktop, Documents, Downloads and iCloud Drive are private: a service is"
  echo "not an app, so there is no window to ask you for permission through, and"
  echo "every read fails. Starting the bridge by hand is unaffected — it is only"
  echo "the background service that cannot live there."
  echo ""

  if [[ -e "$target" ]]; then
    err "Move this folder out of $(dirname "$ROOT" | sed "s|$HOME|~|") yourself, then double-click this file again."
    err "It cannot be moved to ${target/#$HOME/~}: something is already there."
    hold_window
    exit 1
  fi

  echo "This can move the whole bridge folder for you:"
  echo "  from  ${ROOT/#$HOME/~}"
  echo "  to    ${target/#$HOME/~}"
  echo ""
  echo "Nothing is lost — it is the same folder, one level up, and the launchers"
  echo "inside it keep working from there."
  echo ""

  if [[ "${BRIDGE_AUTO_INSTALL:-0}" == "1" ]]; then
    reply="y"
  elif [[ -t 0 ]]; then
    read -r -p "Move it now? [Y/n] " reply || reply="n"
  else
    err "Move the folder to ${target/#$HOME/~}, then run this again."
    exit 1
  fi

  case "${reply:-y}" in
    y | Y | yes | YES | Yes) ;;
    *)
      echo ""
      echo "Nothing moved. Move the folder to ${target/#$HOME/~} when you want the"
      echo "service, or keep using \"Start USB bridge.command\" as you do now."
      hold_window
      exit 0
      ;;
  esac

  if ! mv "$ROOT" "$target"; then
    err "The folder could not be moved. Move it in Finder, then double-click this file again."
    hold_window
    exit 1
  fi

  echo ""
  bold "Moved to ${target/#$HOME/~}"
  echo ""
  # Carrying on from the old path would install a service pointing at a folder
  # that no longer exists, so the rest of the work belongs to the moved copy.
  exec bash "$target/scripts/agent.sh" install
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

  if protected_location; then
    move_out_of_protected_location
  fi

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
      # The answer may be coming from a bridge started by hand, which holds the
      # port and leaves the service standing by. That is a fine state, but it is
      # not the one just promised, so it gets said.
      if curl -s --max-time 20 "${APP_URL}/api/status" | grep -q '"serving":true'; then
        echo "The bridge now starts by itself when you log in, and starts again if"
        echo "it stops. There is no window to keep open: open the page or the"
        echo "installed app whenever you need it."
      else
        echo "A bridge you started by hand is holding port ${PORT}. It keeps working"
        echo "as it is; the service takes over within a minute of that window being"
        echo "closed, and from then on there is no window to keep open."
      fi
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

  # A registered service that cannot start retries every thirty seconds for as
  # long as the machine is on. Leaving that behind would be worse than not
  # having installed it, so it is taken back out.
  warn "The service did not come up on port ${PORT}, so it has been removed again."
  echo ""
  if tail -40 "$LOG" 2>/dev/null | grep -q "not permitted"; then
    echo "macOS refused it access to the bridge folder. If the folder sits on an"
    echo "external disk, or in a folder you granted to Terminal alone, move it to"
    echo "your home folder and try again."
  else
    echo "What it printed on the way down is in:"
    echo "  $LOG"
  fi
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo ""
  echo "\"Start USB bridge.command\" still works the way it always did."
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
