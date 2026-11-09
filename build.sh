#!/bin/bash
# Builds "OLEDial.app" (universal: Apple Silicon + Intel).
# Requires Xcode 26+ (for the Liquid Glass APIs). Runs on macOS 14+; Liquid Glass on macOS 26+.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/OLEDial.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  echo "▸ Compiling ${ARCH}…"
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$ARCH-apple-macos14.0" \
    Sources/*.swift \
    -o "build/OLEDial-$ARCH"
done
lipo -create build/OLEDial-arm64 build/OLEDial-x86_64 -output "$APP/Contents/MacOS/OLEDial"
rm build/OLEDial-arm64 build/OLEDial-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/* "$APP/Contents/Resources/"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ -n "${APP_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
fi

# Signing: CI passes SIGN_IDENTITY (SHA-1 of a stable self-signed certificate) so the
# app keeps the same identity across builds and macOS keeps its Accessibility permission.
# Without it (local builds, forks) the app is signed ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "▸ Signing ad-hoc"
else
  echo "▸ Signing with certificate $SIGN_IDENTITY"
fi
codesign --force --deep --timestamp=none \
  --identifier "io.github.jiayinh.OLEDial" \
  ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --verbose "$APP"
codesign --display --requirements - "$APP" 2>&1 | sed 's/^/  /'


echo
echo "Built: $PWD/$APP"
