#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Set FROG_SIGN_IDENTITY to a Developer ID identity for distribution builds.
# Local builds are ad-hoc signed. A stable installed signed app retains permissions more reliably.
configuration="${CONFIGURATION:-release}"
args=(-c "$configuration")
if [[ "${FROG_UNIVERSAL:-0}" == "1" ]]; then args+=(--arch arm64 --arch x86_64); fi
swift build "${args[@]}"
binary_dir="$(swift build "${args[@]}" --show-bin-path)"
app="dist/Frog.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swift scripts/make-icon.swift dist/Frog.iconset
iconutil -c icns dist/Frog.iconset -o "$app/Contents/Resources/Frog.icns"
cp "$binary_dir/Frog" "$app/Contents/MacOS/Frog"
cp native/Info.plist "$app/Contents/Info.plist"
chmod +x "$app/Contents/MacOS/Frog"
codesign --force --options runtime --sign "${FROG_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" dist/Frog-macOS.zip
(cd dist && shasum -a 256 Frog-macOS.zip > SHA256SUMS)
echo "Built $app"
echo "Packaged dist/Frog-macOS.zip"
echo "Checksum: dist/SHA256SUMS"
echo "Move Frog.app to /Applications before enabling Start at Login."
