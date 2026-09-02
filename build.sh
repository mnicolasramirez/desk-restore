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

# ---------------------------------------------------------------------------
# Companion launcher: "Restore Desk Layout.app"
#
# For a docking cadence measured in weeks, keeping the agent resident to catch
# two events a month is a poor trade. This is a Spotlight-searchable one-shot:
# type its name, press Return, windows are restored, nothing stays running.
#
# It needs no permissions of its own. The work happens inside Desk Restore,
# which already holds the Accessibility grant.
# ---------------------------------------------------------------------------
build_launcher() {
  local NAME="Restore Desk Layout"
  local L="$STAGE/$NAME.app"
  rm -rf "$L"
  mkdir -p "$L/Contents/MacOS"

  cat > "$L/Contents/Info.plist" <<LPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>              <string>$NAME</string>
	<key>CFBundleDisplayName</key>       <string>$NAME</string>
	<key>CFBundleIdentifier</key>        <string>com.nico.desk-restore.launcher</string>
	<key>CFBundleExecutable</key>        <string>launcher</string>
	<key>CFBundlePackageType</key>       <string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key>           <string>1.0.0</string>
	<key>LSMinimumSystemVersion</key>    <string>$DEPLOYMENT_TARGET</string>
	<key>LSUIElement</key>               <true/>
	<key>LSBackgroundOnly</key>          <false/>
</dict>
</plist>
LPLIST

  cat > "$L/Contents/MacOS/launcher" <<'LSCRIPT'
#!/bin/zsh
# If the agent is already resident, ask it over its URL scheme. If it is not,
# launch it in one-shot mode so it restores and exits without going resident.
if pgrep -x "Desk Restore" >/dev/null 2>&1; then
  open "deskrestore://restore"
else
  open -a "Desk Restore" --args --restore-and-quit
fi
LSCRIPT
  chmod +x "$L/Contents/MacOS/launcher"
  plutil -lint "$L/Contents/Info.plist" >/dev/null

  if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$SIGN_IDENTITY" \
      --identifier "com.nico.desk-restore.launcher" --timestamp=none "$L" 2>/dev/null
  else
    codesign --force --sign - --identifier "com.nico.desk-restore.launcher" "$L" 2>/dev/null
  fi
  print -r -- "$L"
}

echo "==> Building the one-shot launcher"
LAUNCHER="$(build_launcher)"
echo "    built: ${LAUNCHER:t}"

if [[ $INSTALL -eq 1 ]]; then
  LDEST="$INSTALL_DIR/${LAUNCHER:t}"
  osascript -e "tell application \"Restore Desk Layout\" to quit" >/dev/null 2>&1 || true
  rm -rf "$LDEST"
  cp -R "$LAUNCHER" "$LDEST"
  echo "    installed: $LDEST"
fi

echo "==> Done."
