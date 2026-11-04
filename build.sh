#!/bin/bash
# Builds "OLEDial.app" (universal: Apple Silicon + Intel).
# Requires Xcode 26+ (for the Liquid Glass APIs). Runs on macOS 14+; Liquid Glass on macOS 26+.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/OLEDial.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  echo "▸ Compiling $ARCH…"
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$ARCH-apple-macos14.0" \
    Sources/*.swift \
    -o "build/OLEDial-$ARCH"
done
lipo -create build/OLEDial-arm64 build/OLEDial-x86_64 -output "$APP/Contents/MacOS/OLEDial"
rm build/OLEDial-arm64 build/OLEDial-x86_64

cp Info.plist "$APP/Contents/Info.plist"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ -n "${APP_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
fi

codesign --force --deep --sign - "$APP"   # ad-hoc signature
codesign --verify --verbose "$APP"

echo
echo "Built: $PWD/$APP"
