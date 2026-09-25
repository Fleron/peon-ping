#!/bin/bash
# Build Peon.app: a notification sender whose Notification Center icon is the peon.
# Usage: build.sh [icon_png] [out_dir]   (defaults: ../../docs/peon-icon.png, ~/Applications)
set -euo pipefail

src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
icon_png="${1:-$src_dir/../../docs/peon-icon.png}"
out_dir="${2:-$HOME/Applications}"
app="$out_dir/Peon.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O "$src_dir/main.swift" -o "$app/Contents/MacOS/peon-notify"
cp "$src_dir/Info.plist" "$app/Contents/Info.plist"

iconset="$(mktemp -d "${TMPDIR:-/tmp}/peon-icon.XXXXXX")/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$icon_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

codesign --force --sign - "$app"
# Launch Services must know the bundle so a notification click can relaunch it.
"$lsregister" -f "$app" 2>/dev/null || true
echo "$app"
