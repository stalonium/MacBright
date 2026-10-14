#!/bin/bash
# Builds MacBright.app into ./build. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MacBright"

APP="build/MacBright.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacBright"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MacBright 2>/dev/null || true
    rm -rf /Applications/MacBright.app
    cp -R "$APP" /Applications/
    touch /Applications/MacBright.app # nudge Finder/Dock to pick up the new icon
    open /Applications/MacBright.app
    echo "Installed to /Applications/MacBright.app"
fi
