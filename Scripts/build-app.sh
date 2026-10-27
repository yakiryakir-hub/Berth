#!/bin/bash
# Builds Berth.app — a single-binary menu bar app. The WebDAV server and MTP
# stack live in the app process; mounting uses macOS's built-in mount_webdav.
# No extensions, no kexts, no provisioning profiles.
#
# Usage: Scripts/build-app.sh [--install]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Berth"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> Building release binary..."
swift build -c release --product Berth
BIN_PATH="$(swift build -c release --product Berth --show-bin-path)"

# Assemble under /tmp, not the project dir: ~/Documents is iCloud-synced and
# fileproviderd re-tags bundle directories mid-signing, which makes codesign
# fail with "resource fork / detritus" errors. Same lesson as Envy.
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT
TMP_APP="$BUILD_TMP/$APP_NAME.app"

echo "==> Assembling $APP_NAME.app..."
mkdir -p "$TMP_APP/Contents/MacOS" "$TMP_APP/Contents/Resources"
cp "$BIN_PATH/Berth" "$TMP_APP/Contents/MacOS/Berth"
cp "$ROOT_DIR/build-resources/Info.plist" "$TMP_APP/Contents/Info.plist"
cp "$ROOT_DIR/build-resources/AppIcon.icns" "$TMP_APP/Contents/Resources/AppIcon.icns"

# Volume (sidebar) glyph: a tablet silhouette instead of the generic disk icon.
# Rendered from an SF Symbol at build time, then packed into an .icns by
# iconutil (sips -s format icns is unreliable on this toolchain).
echo "==> Rendering volume icon..."
VOLUME_PNG="$BUILD_TMP/volume-icon.png"
VOLUME_ICNS="$BUILD_TMP/VolumeIcon.icns"
ICONSET="$BUILD_TMP/volume.iconset"
swiftc "$ROOT_DIR/Scripts/render-volume-icon.swift" -o "$BUILD_TMP/render-volume-icon"
"$BUILD_TMP/render-volume-icon" "$VOLUME_PNG"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for sz in 16 32 128 256 512 1024; do
  sips -z $sz $sz "$VOLUME_PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
done
iconutil -c icns "$ICONSET" -o "$VOLUME_ICNS"
cp "$VOLUME_ICNS" "$TMP_APP/Contents/Resources/VolumeIcon.icns"

echo "==> Signing..."
SIGNING_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -z "$SIGNING_IDENTITY" ]; then
  echo "    No Developer ID identity found; ad-hoc signing (local test only)."
  SIGNING_IDENTITY="-"
else
  echo "    Using: $SIGNING_IDENTITY"
fi
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$TMP_APP"
codesign --verify --strict "$TMP_APP"
echo "==> Signature verified."

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
ditto "$TMP_APP" "$APP_BUNDLE"
echo "==> Built: $APP_BUNDLE"

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications..."
  # Quit cleanly rather than killall: a hard kill terminates the app while it
  # holds an open USB pipe mid-transfer, which leaves the MTP device's endpoint
  # wedged until it's physically replugged. A graceful quit runs the app's
  # unmount + USB-disconnect path first.
  osascript -e 'tell application "Berth" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -x Berth >/dev/null || break; sleep 1; done
  killall Berth 2>/dev/null || true   # fallback if it didn't quit
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "==> Installed and launched."
fi
