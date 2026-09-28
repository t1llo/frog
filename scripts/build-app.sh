#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Set FROG_SIGN_IDENTITY to a Developer ID identity for distribution builds.
# Local builds are ad-hoc signed. A stable installed signed app retains permissions more reliably.
configuration="${CONFIGURATION:-release}"
args=(-c "$configuration" --disable-keychain)
if [[ "${FROG_UNIVERSAL:-0}" == "1" ]]; then args+=(--arch arm64 --arch x86_64); fi
swift build "${args[@]}"
binary_dir="$(swift build "${args[@]}" --show-bin-path)"
app="dist/Frog.app"
# Recreate only this generated bundle so removed resources cannot survive a rebuild.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto .build/checkouts/FluidAudio/LICENSE "$app/Contents/Resources/FluidAudio-LICENSE.txt"
swift scripts/make-icon.swift dist/Frog.iconset
iconutil -c icns dist/Frog.iconset -o "$app/Contents/Resources/Frog.icns"
cp "$binary_dir/Frog" "$app/Contents/MacOS/Frog"
cp native/Info.plist "$app/Contents/Info.plist"
if [[ -n "${FROG_VERSION:-}" ]]; then
    [[ "$FROG_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'FROG_VERSION must be a semantic version, such as 1.0.0.' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $FROG_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${FROG_BUILD_NUMBER:-}" ]]; then
    [[ "$FROG_BUILD_NUMBER" =~ ^[0-9]+$ ]] || exit 1
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $FROG_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
for localization in native/FrogApp/Resources/*.lproj; do
    ditto "$localization" "$app/Contents/Resources/$(basename "$localization")"
done
# Native package resources include MLX's compiled Metal library.
for bundle in "$binary_dir"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done
metal_library="$app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ ! -s "$metal_library" ]]; then
    echo 'MLX Metal resources are missing. Build with the Xcode SwiftBuild toolchain; do not distribute this bundle.' >&2
    exit 1
fi
chmod +x "$app/Contents/MacOS/Frog"
sign_args=(--force --entitlements native/Frog.entitlements --sign "${FROG_SIGN_IDENTITY:--}")
# Hardened library validation requires a real signing team for embedded frameworks.
# Ad-hoc development builds have no Team ID; distribution builds retain runtime protection.
if [[ "${FROG_SIGN_IDENTITY:--}" != "-" ]]; then sign_args+=(--options runtime --timestamp); fi
# Sign nested Sparkle code from the inside out, retaining its framework symlinks.
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
nested_args=(--force --sign "${FROG_SIGN_IDENTITY:--}")
if [[ "${FROG_SIGN_IDENTITY:--}" != "-" ]]; then nested_args+=(--options runtime --timestamp); fi
codesign "${nested_args[@]}" "$sparkle/XPCServices/Downloader.xpc"
codesign "${nested_args[@]}" "$sparkle/XPCServices/Installer.xpc"
codesign "${nested_args[@]}" "$sparkle/Autoupdate"
codesign "${nested_args[@]}" "$sparkle/Updater.app"
codesign "${nested_args[@]}" "$app/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" dist/Frog-macOS.zip
(cd dist && shasum -a 256 Frog-macOS.zip > SHA256SUMS)
echo "Built $app"
echo "Packaged dist/Frog-macOS.zip"
echo "Checksum: dist/SHA256SUMS"
echo "Move Frog.app to /Applications before enabling Start at Login."
