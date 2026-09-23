#!/bin/bash
# Credentials are read from Keychain by notarytool, never from repository files.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

identity="${FROG_SIGN_IDENTITY:-}"
profile="${FROG_NOTARY_PROFILE:-frog-notary}"
if [[ "$identity" != "Developer ID Application: "* ]]; then
    echo 'Set FROG_SIGN_IDENTITY to the full Developer ID Application certificate name.' >&2
    echo 'List installed certificates with: security find-identity -v -p codesigning' >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -Fq "\"$identity\""; then
    echo 'The specified Developer ID Application identity is not available in Keychain.' >&2
    exit 1
fi

# Check credentials before spending time on the universal build.
xcrun notarytool history --keychain-profile "$profile" >/dev/null
FROG_SIGN_IDENTITY="$identity" FROG_UNIVERSAL=1 CONFIGURATION=release bash scripts/build-app.sh

echo 'Submitting to Apple. This may take several minutes.'
if ! xcrun notarytool submit dist/Frog-macOS.zip \
    --keychain-profile "$profile" --wait --output-format json > dist/notarization.json; then
    echo 'Submission did not complete. Inspect dist/notarization.json before retrying.' >&2
    echo "Check submission status with: xcrun notarytool history --keychain-profile \"$profile\"" >&2
    exit 1
fi
status="$(plutil -extract status raw -o - dist/notarization.json)"
submission_id="$(plutil -extract id raw -o - dist/notarization.json)"
if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$submission_id" --keychain-profile "$profile" dist/notarization-log.json
    echo "Apple returned $status. Inspect dist/notarization-log.json; do not publish this build." >&2
    exit 1
fi

xcrun stapler staple dist/Frog.app
xcrun stapler validate dist/Frog.app
codesign --verify --deep --strict dist/Frog.app
spctl --assess --type execute --verbose=2 dist/Frog.app

# Stapling changes the bundle: recreate the ZIP and its checksum afterwards.
ditto -c -k --sequesterRsrc --keepParent dist/Frog.app dist/Frog-macOS.zip
(cd dist && shasum -a 256 Frog-macOS.zip > SHA256SUMS)
echo 'Notarized and verified: dist/Frog-macOS.zip and dist/SHA256SUMS'
echo 'Release assets are ready for upload; this script does not publish them.'
