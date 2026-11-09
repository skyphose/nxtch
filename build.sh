#!/bin/zsh
# Builds Nxtch.app next to this script.
# Usage: ./build.sh [--run] [--install]   (--install copies it to /Applications and runs it from there)
# Uses swiftc directly (SwiftPM in some Command Line Tools installs is broken).
set -euo pipefail
cd "$(dirname "$0")"
APP=Nxtch.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" .build
swiftc -O -swift-version 5 -target arm64-apple-macosx14.2 \
  -framework CoreAudio -framework AudioToolbox -framework AppKit -framework SwiftUI -framework QuickLookThumbnailing -framework Carbon \
  Sources/Nxtch/*.swift -o "$APP/Contents/MacOS/Nxtch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --sign - "$APP"   # hardened runtime: blocks DYLD_INSERT_LIBRARIES injection
echo "Built $(pwd)/$APP"
if [[ " $* " == *" --install "* ]]; then
  pkill -x Nxtch 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/
  echo "Installed /Applications/$APP"
  open "/Applications/$APP"
elif [[ " $* " == *" --run "* ]]; then
  pkill -x Nxtch 2>/dev/null && sleep 1 || true
  open "$APP"
fi
