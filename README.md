# Frog

A **native SwiftUI macOS writing assistant** that lives in your menu bar. Select text in another app, press a hotkey, and Frog proofreads, fixes spelling, polishes an email, translates, or applies your own instructions. Results are copied to your clipboard and replace the selection when the original field is still safe to edit.

**macOS 14+ · Apple silicon and Intel · Bring your own API key or local model**

## Build and run

With Xcode 26+ (Swift 6.2 or newer) installed:

```sh
swift test
bash scripts/build-app.sh
open dist/Frog.app
```

For Xcode development, open **`native/Frog.xcodeproj`** and select the **Frog-macOS** scheme. The root `Package.swift` can also be opened in Xcode. There are no third-party package dependencies, Go backend, Node installation, or embedded web UI.

If your selected toolchain is Command Line Tools, prefix build/test commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` to use Xcode's Swift and XCTest frameworks.

Copy `dist/Frog.app` to `/Applications` before enabling **Start at Login**. Local builds are ad-hoc signed. To build for both CPU architectures:

```sh
FROG_UNIVERSAL=1 bash scripts/build-app.sh
```

For distribution, set `FROG_SIGN_IDENTITY` to your Developer ID Application identity, then notarize/staple the app using your Apple Developer account. Signing and notarization credentials are not included in the repository. Rebuilding an ad-hoc-signed application can require granting Accessibility access again.

## First use

1. Open Frog from the menu-bar icon. Add a provider in **Providers**, select a model and use **Test Connection**. Set a default provider or choose providers separately for each rule.
2. In **Settings**, grant Frog Accessibility access in macOS System Settings. This is needed for external selection capture/replacement, not for the manual text tool.
3. In **Rules**, configure a preset or create a custom rule. Each rule has independent instructions, provider/model, target language, hotkey and enabled state.
4. Select text in a supported editable application, then press the hotkey. Frog runs without opening its window. Use the menu to see status or cancel a request.
5. Optionally enable login startup and history. Closing the settings window leaves Frog running; **Quit Frog** stops it.

### Default shortcuts

| Shortcut | Preset |
| --- | --- |
| Control + Shift + C | Proofread |
| Control + Shift + S | Spelling only |
| Control + Shift + E | Polish email |
| Control + Shift + T | Translate to English |
| Control + Shift + G | Translate to German |

These are configurable physical-key shortcuts. Registration conflicts are shown in Rules. Existing shortcuts from the archived app are not imported automatically.

### Providers

- **OpenAI**, **Anthropic/Claude**, **Google Gemini**: enter your own API key and an available model ID.
- **Ollama**: run Ollama separately, pull a model, then configure `http://localhost:11434` and its model name. No cloud key is required.
- **OpenAI-compatible**: configure an API base URL (typically ending in `/v1`) and model. Local compatible services can use localhost HTTP without a key; remote endpoints use HTTPS.

Keys are stored in macOS Keychain, separately from settings. A blank key field retains the saved key; remove-key controls delete it explicitly. Endpoint compatibility is protocol-specific, not a promise that every provider API is interchangeable. Models must already be available to your account or local server.

### Selection behavior

Frog uses native Accessibility APIs to capture the focused selection and validate its target before replacement. It does not read old clipboard text as a substitute for selection. If you change fields, selection or text while the model is working—or the application does not allow reliable editing—the result remains on the clipboard and Frog explains why replacement was skipped. Some custom editors and secure/read-only fields are unsupported. See [desktop verification](docs/verification.md).

### Local data and history

Settings/history live under `~/Library/Application Support/Frog/`. History is off by default; when enabled it keeps up to 200 records for 30 days, configurable in Settings. It stores input, output, rule and provider/model metadata locally. Turning history off stops new recording and keeps existing records until cleared or expired. Cloud requests send selected text to the configured provider regardless of history settings.

The old app's `~/.config/frog/` data is not automatically imported or removed. Its plaintext API keys, if any, stay in that legacy file until you remove them yourself.

## Development references

- [Product requirements](docs/product.md)
- [Implementation status](docs/status.md) and [verification](docs/verification.md)
- [Native work items](docs/work-items.md) and [integration contracts](docs/native-contract.md)
- [Agent workflow](docs/agent-workflow.md) and [current progress](docs/progress.md)
- [Archive inventory](archive/README.md): former Go/Wails/Svelte app and original Xcode experiment, preserved as reference

For isolated manual testing, launch the executable with `FROG_DATA_DIRECTORY` pointing to a temporary directory. Provider keys still use Keychain IDs; use new provider IDs for test fixtures. CI builds/tests the native package and packages an ad-hoc-signed macOS app; OS permission prompts and real provider accounts require separate desktop verification.
