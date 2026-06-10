#!/usr/bin/env bash
# Build Coffee.app from source.
# Requires the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail

cd "$(dirname "$0")"
APP="Coffee.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "› cleaning"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "› compiling src/main.swift"
swiftc -O src/main.swift -o "$MACOS/Coffee" -framework AppKit

echo "› assembling bundle"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$RES/AppIcon.icns"
cp src/main.swift "$RES/main.swift"   # keep source with the app

echo "› signing (ad-hoc)"
codesign --force --deep -s - "$APP"

echo "✓ built ./$APP"
echo "  Drag it to /Applications, then open it once to finish setup."
