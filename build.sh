#!/bin/bash
# Builds "Project Launcher.app" into ./build. Needs only Apple's Command Line Tools
# (install once with:  xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"
SRC="$(pwd -P)"

APP="build/Project Launcher.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling..."
xcrun -sdk macosx swiftc -parse-as-library -O \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/ProjectLauncher"

cp Info.plist "$APP/Contents/Info.plist"
# Remember where the source lives, for the "Update Project Launcher..." menu item.
plutil -insert PLSourceDir -string "$SRC" "$APP/Contents/Info.plist"

# If you've made the "Project Launcher Local" certificate (see README), sign with it so
# macOS keeps the Accessibility/Automation permissions between updates.
# Otherwise sign ad-hoc (works, but permissions may need re-enabling after each update).
IDENTITY="Project Launcher Local"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" \
   && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signed with \"$IDENTITY\"."
else
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc."
fi

echo ""
echo "Done: $APP"
