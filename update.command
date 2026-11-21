#!/bin/bash
# Gets the latest version from GitHub, rebuilds it and reinstalls Project Launcher.
# Run it from Terminal (./update.command), double-click it, or use the app's
# "Check for Updates…" menu item.
set -euo pipefail
cd "$(dirname "$0")"

if [ -d .git ]; then
  echo "Getting the latest version..."
  git pull --ff-only
  echo ""
fi

bash build.sh

if pgrep -x ProjectLauncher >/dev/null; then
  echo "Quitting Project Launcher..."
  osascript -e 'tell application id "local.ihsaan.projectlauncher" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    pgrep -x ProjectLauncher >/dev/null || break
    sleep 0.25
  done
fi

rm -rf "/Applications/Project Launcher.app"
cp -R "build/Project Launcher.app" /Applications/
open "/Applications/Project Launcher.app" || { sleep 1; open "/Applications/Project Launcher.app"; }
echo ""
echo "Updated. You can close this window."
