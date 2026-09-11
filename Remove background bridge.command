#!/bin/bash
# Double-click this file to stop the bridge running in the background and to
# remove the one file the service left outside this folder.
#
# The bridge itself stays: "Start USB bridge.command" works as it always did.
cd "$(dirname "$0")" || exit 1
exec bash scripts/agent.sh remove
