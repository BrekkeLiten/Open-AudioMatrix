#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Open AudioMatrix"
BUNDLE_ID="io.github.brekkeliten.openaudiomatrix"
BUILD_CONFIG="${1:-release}"
BUILD_DIR=".build/${BUILD_CONFIG}"
APP_DIR="dist/${APP_NAME}.app"

echo "==> Building AudioMatrixApp + AudioMatrixEngine (${BUILD_CONFIG})"
swift build -c "$BUILD_CONFIG" --product AudioMatrixApp
swift build -c "$BUILD_CONFIG" --product AudioMatrixEngine

echo "==> Packaging ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Main app executable.
cp "$BUILD_DIR/AudioMatrixApp" "$APP_DIR/Contents/MacOS/${APP_NAME}"
# Engine daemon, bundled next to the app executable so it is found after install.
cp "$BUILD_DIR/AudioMatrixEngine" "$APP_DIR/Contents/MacOS/AudioMatrixEngine"

cp Supporting/AudioMatrixApp-Info.plist "$APP_DIR/Contents/Info.plist"

ICON_SRC="Sources/AudioMatrixApp/Resources/AppIcon.png"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${APP_NAME}" "$APP_DIR/Contents/Info.plist"

chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/AudioMatrixEngine"

# Ad-hoc code signature gives the app a stable identity so macOS keeps its
# audio-capture / microphone permission grants across launches.
echo "==> Ad-hoc code signing"
codesign --force --sign - "$APP_DIR/Contents/MacOS/AudioMatrixEngine"
codesign --force --sign - --options runtime --entitlements Supporting/OpenAudioMatrix.entitlements "$APP_DIR/Contents/MacOS/${APP_NAME}" 2>/dev/null \
  || codesign --force --sign - "$APP_DIR/Contents/MacOS/${APP_NAME}"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: ${APP_DIR}"
echo "    open \"${APP_DIR}\""
