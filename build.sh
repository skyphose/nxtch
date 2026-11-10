#!/bin/zsh
# Builds Nxtch.app next to this script.
# Usage: ./build.sh [--run] [--install] [--uninstall]
#   --install    copies it to /Applications and runs it from there
#   --uninstall  removes the app, its settings, its data and its permissions (builds nothing)
#
# Signs with your "Apple Development" certificate when one is valid, so macOS keeps the audio and
# Accessibility grants across rebuilds. Without one it signs ad hoc, and macOS may ask again after
# every build. Set SIGN_ID to pick a specific identity.
set -euo pipefail
cd "$(dirname "$0")"
APP=Nxtch.app
BUNDLE_ID=dev.nxtch.app

if [[ " $* " == *" --uninstall "* ]]; then
  # Launch at login is registered against the installed app, so turn it off before removing it.
  [[ -x "/Applications/$APP/Contents/MacOS/Nxtch" ]] && "/Applications/$APP/Contents/MacOS/Nxtch" --unregister-login-item || true
  pkill -x Nxtch 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/$APP" "$APP"
  rm -rf "$HOME/Library/Application Support/nxtch"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "Uninstalled nxtch: app, settings, shelf, clipboard history and permissions removed."
  exit 0
fi

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
