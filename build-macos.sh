#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

output="${1:-$PWD/dist}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Cursor Click.app"
resources="$app/Contents/Resources"
browser="$resources/BrowserAutomation"
iconset="$stage/CursorClick.iconset"
mkdir -p "$app/Contents/MacOS" "$browser" "$iconset"

cp macOS/Info.plist "$app/Contents/"
cp browser/{desktop.js,server.js,package.json,package-lock.json} "$browser/"
cp -R browser/public "$browser/"
(cd "$browser" && npm ci --omit=dev)

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" assets/icon.png \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/CursorClick.icns"
xcrun swiftc -O -parse-as-library macOS/*.swift -o "$app/Contents/MacOS/CursorClick"
ditto --noextattr --norsrc "$app" "$stage/signed/Cursor Click.app"
app="$stage/signed/Cursor Click.app"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
if [[ -e "$output/Cursor Click.app" ]]; then
    echo "Choose an output directory that does not already contain Cursor Click.app." >&2
    exit 1
fi
ditto "$app" "$output/Cursor Click.app"
