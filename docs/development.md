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
- `archive`: previous implementations, retained as reference and excluded from builds.

For isolated manual testing, launch the executable with `FROG_DATA_DIRECTORY` pointing to a temporary directory. Keys still use Keychain provider IDs; use fresh IDs for fixtures. README screenshots show the real native views with isolated example settings, not a running model request.

## Release packaging

Local and CI builds use ad-hoc signing. For a Developer ID build, set `FROG_SIGN_IDENTITY` to the installed signing identity. Notarization requires the maintainer’s Apple Developer credentials and must be performed separately before calling a release notarized.

Preview release assets are `Frog-macOS.zip` and `SHA256SUMS`. The build/test workflow also uploads them as a GitHub Actions artifact.

Before a release, run the automated checks and the [desktop verification steps](verification.md).
