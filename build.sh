#!/bin/zsh
# Build Desk Restore from the vault source and install it locally.
#
# Builds with swiftc plus the Command Line Tools. Xcode is not required.
# Source of truth is this folder; the built app is assembled in
# ~/desk-restore-build and installed to /Applications.
#
#   ./build.sh              build, sign, install to /Applications
#   ./build.sh --no-install build and sign only, leave it in the build folder
#
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SRC="$SCRIPT_DIR/Sources"
BUILD="${DESK_RESTORE_BUILD_DIR:-$HOME/desk-restore-build}"
STAGE="$BUILD/stage"

APP_NAME="Desk Restore"
BUNDLE_ID="com.nico.desk-restore"
VERSION="0.1.0"
DEPLOYMENT_TARGET="14.0"
SIGN_IDENTITY="${DESK_RESTORE_SIGN_IDENTITY:-Desk Restore Dev}"
INSTALL_DIR="${DESK_RESTORE_INSTALL_DIR:-/Applications}"

INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

APP="$STAGE/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RESOURCES_DIR="$APP/Contents/Resources"

echo "==> Cleaning stage"
rm -rf "$STAGE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "==> Compiling ($(ls "$SRC"/*.swift | wc -l | tr -d ' ') sources, target macOS $DEPLOYMENT_TARGET)"
ARCH="$(uname -m)"
swiftc \
  -O \
  -parse-as-library \
  -target "${ARCH}-apple-macosx${DEPLOYMENT_TARGET}" \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework ServiceManagement \
  -o "$MACOS_DIR/$APP_NAME" \
  "$SRC"/*.swift

echo "==> Copying Info.plist"
# Shared with the Xcode project, so both build paths cannot drift apart.
cp "$SCRIPT_DIR/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "    version $VERSION"

echo "==> Signing"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
  echo "    signed with '$SIGN_IDENTITY'"
else
  echo "    WARNING: '$SIGN_IDENTITY' not in the keychain — falling back to ad-hoc."
  echo "    The Accessibility grant will NOT survive rebuilds. See README section 'Signing'."
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "    designated => $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

if [[ $INSTALL -eq 1 ]]; then
  DEST="$INSTALL_DIR/$APP_NAME.app"
  echo "==> Installing to $DEST"
  if [[ ! -w "$INSTALL_DIR" ]]; then
    echo "    $INSTALL_DIR is not writable; falling back to ~/Applications"
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    DEST="$INSTALL_DIR/$APP_NAME.app"
  fi
  # Quit a running copy so the bundle can be replaced cleanly.
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "    installed: $DEST"
else
  echo "==> Not installing (--no-install). Built at: $APP"
fi

echo "==> Done."
