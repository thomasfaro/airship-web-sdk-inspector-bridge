#!/bin/bash
# Double-click this file. It installs whatever is missing — Node.js, the Android
# debugging tools — inside this folder, then starts the bridge and opens the page.
#
# The window that opens is the bridge itself. Closing it stops the bridge.
cd "$(dirname "$0")" || exit 1
exec bash scripts/start.sh
