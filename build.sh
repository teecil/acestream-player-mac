#!/bin/bash
# Builds "AceStream Player.app" (arm64) and a drag-to-install DMG into ./build
# Requirements: macOS 14+, Xcode or Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AceStream Player"
EXECUTABLE="AceStreamPlayer"
ARCH="${ARCH:-arm64}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Compiling ($ARCH, release)"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

echo "==> Assembling app bundle"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> Rendering icon"
if swift scripts/make_icon.swift "$BUILD_DIR/AppIcon.iconset" && \
   iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  rm -rf "$BUILD_DIR/AppIcon.iconset"
else
  echo "warning: icon generation failed, continuing without a custom icon" >&2
fi

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"
lipo -archs "$APP/Contents/MacOS/$EXECUTABLE" || true

echo "==> Packaging DMG"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$BUILD_DIR/AceStreamPlayer.dmg" >/dev/null
rm -rf "$STAGE"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/AceStreamPlayer.zip"

echo
echo "Done:"
echo "  $APP"
echo "  $BUILD_DIR/AceStreamPlayer.dmg"
