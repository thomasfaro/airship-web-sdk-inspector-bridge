#!/bin/bash
# Double-click this file once. macOS then keeps the bridge running for you: it
# starts at login, comes back if it stops, and the page — or the installed app
# icon — works whenever you open it, with no window to keep open.
#
# "Remove background bridge.command" undoes it.
cd "$(dirname "$0")" || exit 1
exec bash scripts/agent.sh install
