#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
app="$PWD/../VolumeMixer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/VolumeMixer "$app/Contents/MacOS/VolumeMixer"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier dev.samir.VolumeMixer "$app"
printf '%s\n' "$app"
