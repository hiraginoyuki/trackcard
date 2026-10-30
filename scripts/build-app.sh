#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
bin_path="$(swift build -c release --show-bin-path)"
app_path="$PWD/build/Trackpad Preview.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/TrackpadPreview" "$app_path/Contents/MacOS/TrackpadPreview"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
printf '%s\n' "$app_path"
