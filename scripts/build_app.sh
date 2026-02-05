#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TranslatorHotkey"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
SWIFTPM_CACHE="$ROOT_DIR/.swiftpm-cache"
CLANG_CACHE="$ROOT_DIR/.clang-module-cache"

mkdir -p "$ROOT_DIR/dist"
mkdir -p "$SWIFTPM_CACHE" "$CLANG_CACHE"

export SWIFTPM_CACHE_PATH="$SWIFTPM_CACHE"
export SWIFT_MODULE_CACHE_PATH="$CLANG_CACHE"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$ROOT_DIR/Assets/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built: $APP_DIR"
