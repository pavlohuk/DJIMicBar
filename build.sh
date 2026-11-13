#!/bin/zsh
# Builds "DJI Mic Bar.app" into ./build. Requires only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DJI Mic Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macos13.0" \
    -framework IOUSBHost -framework IOKit \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/DJIMicBar"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/*.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

echo "Built: $APP"
