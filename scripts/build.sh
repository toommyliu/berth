#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

swift build -c release
app=build/Berth.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Berth "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
codesign --force --sign - "$app"
echo "$app"
