#!/bin/bash
# Build a notification sender app whose Notification Center icon is a unit portrait.
# Usage: build.sh [name] [bundle_id] [icon] [out_dir]
#   defaults: Peon, com.fleron.peon-notify, icons/peon.gif, ~/Applications
set -euo pipefail

src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="${1:-Peon}"
bundle_id="${2:-com.fleron.peon-notify}"
icon="${3:-$src_dir/icons/peon.gif}"
out_dir="${4:-$HOME/Applications}"
app="$out_dir/$name.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O "$src_dir/main.swift" -o "$app/Contents/MacOS/peon-notify"
cp "$src_dir/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
plutil -replace CFBundleName -string "$name" "$app/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$name" "$app/Contents/Info.plist"

work="$(mktemp -d "${TMPDIR:-/tmp}/peon-icon.XXXXXX")"
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
sips -s format png "$icon" --out "$work/source.png" >/dev/null
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$work/source.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$work/source.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$work"

codesign --force --sign - "$app"
# Launch Services must know the bundle so a notification click can relaunch it.
"$lsregister" -f "$app" 2>/dev/null || true
echo "$app"
