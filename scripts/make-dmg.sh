#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Open AudioMatrix"
BUILD_CONFIG="${1:-release}"
APP_DIR="dist/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Supporting/AudioMatrixApp-Info.plist 2>/dev/null || echo 1.0)"
DMG_PATH="dist/${APP_NAME} ${VERSION}.dmg"
STAGING_DIR="dist/dmg-staging"

# Build + package the .app first.
"$ROOT_DIR/scripts/package-app.sh" "$BUILD_CONFIG"

echo "==> Staging DMG contents"
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Building ${DMG_PATH}"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> Done: ${DMG_PATH}"
ls -lh "$DMG_PATH"
