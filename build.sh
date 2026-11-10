#!/bin/zsh
# Builds Nxtch.app next to this script.
# Usage: ./build.sh [--run] [--install]   (--install copies it to /Applications and runs it from there)
#
# Signs with your "Apple Development" certificate when one is valid, so macOS keeps the audio and
# Accessibility grants across rebuilds. Without one it signs ad hoc, and macOS may ask again after
# every build. Set SIGN_ID to pick a specific identity.
set -euo pipefail
cd "$(dirname "$0")"
APP=Nxtch.app

swift build -c release
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Nxtch" "$APP/Contents/MacOS/Nxtch"
cp Resources/Info.plist "$APP/Contents/Info.plist"

SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
# Hardened runtime blocks DYLD_INSERT_LIBRARIES injection into nxtch and its permissions.
codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP"
echo "Built $(pwd)/$APP (signed: ${SIGN_ID:-ad hoc})"

if [[ " $* " == *" --install "* ]]; then
  pkill -x Nxtch 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/
  echo "Installed /Applications/$APP"
  open "/Applications/$APP"
elif [[ " $* " == *" --run "* ]]; then
  pkill -x Nxtch 2>/dev/null && sleep 1 || true
  open "$APP"
fi
