#!/bin/bash
# Compila RAMPressureMonitor.app. No necesita Xcode, solo las Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/RAMPressureMonitor.app"
TARGET="$(uname -m)-apple-macos13.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target "$TARGET" \
	-o "$APP/Contents/MacOS/RAMPressureMonitor" \
	Sources/Metrics.swift Sources/main.swift

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Listo: $APP"
