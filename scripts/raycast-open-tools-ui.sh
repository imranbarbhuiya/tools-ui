#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Tools UI
# @raycast.mode silent
# @raycast.packageName Tools UI
#
# Optional parameters:
# @raycast.icon bolt
# @raycast.description Launch Tools UI menu bar process manager

set -euo pipefail

# Prefer installed copy, then repo build
APP_CANDIDATES=(
	"$HOME/Applications/Tools UI.app"
	"/Applications/Tools UI.app"
	"$HOME/Documents/open-source/tools-ui/Tools UI.app"
)

for app in "${APP_CANDIDATES[@]}"; do
	if [[ -d "$app" ]]; then
		open "$app"
		exit 0
	fi
done

# Last resort: launch by bundle name if Spotlight knows it
if open -a "Tools UI" 2>/dev/null; then
	exit 0
fi

echo "Tools UI not found. In Terminal run:"
echo "  cd ~/Documents/open-source/tools-ui && ./scripts/package-app.sh"
echo "  cp -R \"Tools UI.app\" ~/Applications/"
exit 1
