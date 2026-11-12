#!/bin/zsh
# Builds Nxtch.app next to this script.
# Usage: ./build.sh [--run] [--install] [--uninstall] [--make-cert]
#   --install    copies it to /Applications and runs it from there
#   --uninstall  removes the app, its settings, its data and its permissions (builds nothing)
#   --make-cert  makes a signing certificate for this Mac, once (builds nothing)
#
# macOS remembers the audio and Accessibility grants by who signed the app. Signed ad hoc, every
# build is a stranger and macOS asks again. So this signs with, in order: SIGN_ID if you set it,
# your "Apple Development" certificate, or the "nxtch signing" certificate that --make-cert puts
# in your login keychain. With any of those you are asked once and it sticks across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"
if [[ $EUID -eq 0 ]]; then echo "Run build.sh as yourself, not with sudo." >&2; exit 1; fi
APP=Nxtch.app
BUNDLE_ID=dev.nxtch.app

# A real nxtch: named Nxtch.app, not a symlink, with nxtch's bundle id. Nothing else gets run or rm -rf'd.
is_nxtch() {
  [[ "${1:t}" == "$APP" && ! -L "$1" &&
     "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]]
}

CERT_NAME="nxtch signing"

# A self-signed code signing certificate, kept in your login keychain. It only means "built on
# this Mac": it is not from Apple, and Gatekeeper trusts it no more than an ad hoc signature.
if [[ " $* " == *" --make-cert "* ]]; then
  if security find-identity -p codesigning | grep -q "\"$CERT_NAME\""; then
    echo "You already have a \"$CERT_NAME\" certificate. Nothing to do."; exit 0
  fi
  TMP=$(mktemp -d) && trap 'rm -rf "$TMP"' EXIT
  PASS=$(/usr/bin/openssl rand -hex 16)
  # /usr/bin/openssl on purpose: a newer openssl writes a .p12 that the keychain cant read.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$CERT_NAME" \
    -out "$TMP/id.p12" -passout "pass:$PASS"
  # Only codesign may use the key without asking.
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
  echo "Made the \"$CERT_NAME\" certificate in your login keychain. Builds from now on are signed with it."
  echo "macOS may ask once to let codesign use the key: choose Always Allow."
  exit 0
fi

if [[ " $* " == *" --uninstall "* ]]; then
  INSTALLED="/Applications/$APP"
  if [[ -e "$INSTALLED" || -L "$INSTALLED" ]] && ! is_nxtch "$INSTALLED"; then
    echo "$INSTALLED doesnt look like nxtch. Not touching it." >&2; exit 1
  fi
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

# swiftc directly, not swift build: the free command line tools can compile nxtch this way, while
# their swiftpm fails on recent macOS. So full Xcode is not needed. (swift test still uses swiftpm.)
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build
# Both chips in one binary, so the same app runs on Apple silicon and Intel Macs.
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -wmo -module-name Nxtch -target "$ARCH-apple-macosx14.2" \
    -module-cache-path .build/module-cache Sources/Nxtch/*.swift -o ".build/Nxtch-$ARCH"
done
lipo -create .build/Nxtch-arm64 .build/Nxtch-x86_64 -output "$APP/Contents/MacOS/Nxtch"
# Local symbol names are only for debuggers: about half the binary, none of it loaded at run time.
strip -x "$APP/Contents/MacOS/Nxtch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
# Not -v: a self-signed certificate is never "valid" to macOS, and codesign doesnt need it to be.
SIGN_ID=${SIGN_ID:-$(security find-identity -p codesigning | awk -F'"' -v n="$CERT_NAME" '$2 == n {print $2; exit}')}
# Hardened runtime blocks DYLD_INSERT_LIBRARIES injection into nxtch and its permissions.
codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP"
echo "Built $(pwd)/$APP (signed: ${SIGN_ID:-ad hoc})"

if [[ " $* " == *" --install "* ]]; then
  if [[ -e "/Applications/$APP" || -L "/Applications/$APP" ]] && ! is_nxtch "/Applications/$APP"; then
    echo "/Applications/$APP doesnt look like nxtch. Not touching it." >&2; exit 1
  fi
  pkill -x Nxtch 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/
  echo "Installed /Applications/$APP"
  open "/Applications/$APP"
elif [[ " $* " == *" --run "* ]]; then
  pkill -x Nxtch 2>/dev/null && sleep 1 || true
  open "$APP"
fi
