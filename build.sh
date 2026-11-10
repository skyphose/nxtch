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
  INSTALLED="/Applications/$APP"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  # Launch at login is registered against the installed app, so turn it off before removing it.
  [[ -x "$INSTALLED/Contents/MacOS/Nxtch" ]] && "$INSTALLED/Contents/MacOS/Nxtch" --unregister-login-item || true
  # Permissions are looked up through the installed app, so reset them while it still exists.
  if tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1; then PERMS="reset"; else PERMS="NOT reset (remove nxtch by hand in System Settings > Privacy & Security)"; fi
  # Wait for nxtch to be gone: it would write its settings back on the way out.
  pkill -x Nxtch 2>/dev/null || true
  for _ in {1..50}; do pgrep -x Nxtch >/dev/null || break; sleep 0.1; done
  "$LSREGISTER" -u "$INSTALLED" "$PWD/$APP" >/dev/null 2>&1 || true
  rm -rf "$INSTALLED" "$APP"
  rm -rf "$HOME/Library/Application Support/nxtch"
  # Settings, and everything macOS keeps per app. dev.notchmixer.app is the id nxtch had under its first name.
  for ID in "$BUNDLE_ID" dev.notchmixer.app; do
    defaults delete "$ID" 2>/dev/null || true
    rm -rf "$HOME/Library/Preferences/$ID.plist" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" \
           "$HOME/Library/Saved Application State/$ID.savedState" \
           "$(getconf DARWIN_USER_CACHE_DIR)$ID" "$(getconf DARWIN_USER_TEMP_DIR)$ID"
  done
  echo "Uninstalled nxtch: app, settings, caches, shelf and clipboard history removed. Permissions: $PERMS."
  exit 0
fi

swift build -c release
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Nxtch" "$APP/Contents/MacOS/Nxtch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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
