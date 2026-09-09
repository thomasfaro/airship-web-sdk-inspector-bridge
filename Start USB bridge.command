#!/bin/zsh -l
# Double-clickable launcher for the USB bridge, for people who would rather not
# open a terminal. It is a login shell on purpose: Finder starts commands with a
# bare PATH, and node installed through nvm or Homebrew only appears once the
# profile has been read.
#
# The window that opens is the server itself. Closing it stops the bridge.

cd "${0:a:h}" || exit 1

# A zip from Drive is quarantined; Finder then refuses a double-click. Clearing
# it here cannot help the first launch (Gatekeeper runs first), but once the
# script has been allowed — Control-click → Open, or `zsh` from Terminal —
# later double-clicks work.
xattr -dr com.apple.quarantine . 2>/dev/null || true

if ! command -v npm >/dev/null 2>&1; then
  echo "npm was not found."
  echo "Install Node.js from https://nodejs.org, then double-click this file again."
  echo
  read -r "?Press return to close this window."
  exit 1
fi

if [ ! -f dist/extension/injected.js ]; then
  echo "First run: building the collector bundle…"
  npm install --silent && npm run build || exit 1
  echo
fi

exec npm run bridge
