# Development and releases

Frog is a native SwiftUI menu-bar app for macOS 14+. Building requires Xcode 26+ and Swift 6.2+. There are no third-party package dependencies.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
FROG_UNIVERSAL=1 bash scripts/build-app.sh
```

The script produces `dist/Frog.app`, `dist/Frog-macOS.zip`, and `dist/SHA256SUMS`. The zip preserves executable permissions and app bundle structure. With `FROG_UNIVERSAL=1`, it contains arm64 and x86_64 slices. Without it, it builds for the current architecture.

Open `native/Frog.xcodeproj` and choose **Frog-macOS** for Xcode development. The root Swift package can also be opened directly.

## Source layout

- `native/FrogCore`: models, configuration files, history, Keychain, provider clients.
- `native/FrogApp`: SwiftUI views, app lifecycle, shortcuts, Accessibility, login items.
- `native/Tests`: isolated protocol, persistence, configuration transfer, and processing tests.

For isolated manual testing, launch the executable with `FROG_DATA_DIRECTORY` pointing to a temporary directory. Keys still use Keychain provider IDs; use fresh IDs for fixtures. README screenshots show the real native views with isolated example settings, not a running model request.

## Release packaging

Local and CI builds use ad-hoc signing. Developer ID builds use hardened runtime and a secure timestamp. Follow the setup below to sign and notarize a release for direct download.

Preview release assets are `Frog-macOS.zip` and `SHA256SUMS`. The build/test workflow also uploads them as a GitHub Actions artifact.

Before a release, run the automated checks and the [desktop verification steps](verification.md).

### One-time Apple account setup

1. Open **Xcode → Settings → Accounts** (called **Apple Accounts** in some versions). Add your Apple Account if needed and select the team enrolled in the paid Apple Developer Program.
2. Click **Manage Certificates… → + → Developer ID Application**. This creates the certificate and keeps its private key in Keychain. **Apple Development**, **Apple Distribution**, and **Developer ID Installer** are different certificate types. If Developer ID Application is unavailable, check your membership and team permissions with the Account Holder.
3. Run `security find-identity -v -p codesigning` in Terminal. Copy the full `Developer ID Application: … (TEAMID)` name, without the surrounding quotes. The signing Team ID is the value in parentheses on this certificate, not the identifier on an Apple Development certificate.
4. At [account.apple.com](https://account.apple.com/), create an **app-specific password** under **Sign-In and Security**. Then run this command in Terminal:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcrun notarytool store-credentials frog-notary
   ```

   Follow the interactive prompts for your Apple Account email, app-specific password and Team ID. Credentials are validated and saved in Keychain. Do not put the password in a command, repository file, or chat. This is an app-specific password, not your normal Apple Account password.

### Build, sign and notarize

From the repository root, replace the certificate name below with the one from your Keychain:

```sh
export FROG_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
bash scripts/notarize-app.sh
```

The script validates the signing identity and Keychain profile, builds a release for Apple silicon and Intel, signs it, submits it to Apple, requires an **Accepted** result, staples the notarization ticket, and checks the signature and Gatekeeper assessment. It then recreates `dist/Frog-macOS.zip` and `dist/SHA256SUMS` from the stapled app. Upload both files together only after the command succeeds.

Set `FROG_NOTARY_PROFILE` if you saved credentials under a name other than `frog-notary`. Submission metadata and any rejection log stay in ignored `dist/`. If submission is interrupted, inspect `xcrun notarytool history --keychain-profile frog-notary` before retrying. To retrieve Apple's diagnostics, use `xcrun notarytool log SUBMISSION_ID --keychain-profile frog-notary dist/notarization-log.json`.

Once the notarized assets replace a preview release, update that release's notes and README installation text to describe the new signing status. The workflow does not upload assets, change repository visibility, or claim existing preview downloads are notarized.
