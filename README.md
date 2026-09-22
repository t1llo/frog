# Frog

A small macOS writing assistant that lives in your menu bar. Select some text, press a shortcut, and get it proofread, translated, or rewritten in place.

**[Download](https://github.com/t1llo/frog/releases)** · macOS 14+ · Apple silicon and Intel

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/frog-dark.png">
  <img src="docs/images/frog-light.png" alt="Frog’s writing rules in its native macOS interface" width="960">
</picture>

## What it does

- Proofread, fix spelling, polish emails, and translate with built-in rules.
- Create your own rules, each with its own shortcut, language, provider, and model.
- Use OpenAI, Claude, Gemini, an OpenAI-compatible service, or a local model through Ollama.
- Export and import your setup as an editable JSON file.
- Keep an optional local history. It’s off by default.

No Frog account, analytics, or telemetry. Bring your own API key, or use a local model.

## Install

1. Download **Frog-macOS.zip** from [Releases](https://github.com/t1llo/frog/releases), unzip it, and move **Frog.app** to **Applications**.
2. Open Frog and add a provider. For Ollama, start Ollama separately and enter the name of an installed model.
3. Allow Frog in **System Settings → Privacy & Security → Accessibility** to work with text in other apps.

Preview builds aren’t notarized yet. If macOS blocks a downloaded build, use **Open Anyway** in Privacy & Security after trying to open it. You can also [build from source](#build-from-source).

## Use it

Select text in an editable field, then press **Control + Shift + C** to proofread. Change shortcuts and instructions in **Rules**. Other presets cover spelling, email polishing, and translation to English or German.

Frog sends the selected text and your rule to the provider you chose, copies the result, and replaces the selection. If you move to another field or the app can’t safely edit it, the result stays on your clipboard. **Try text** works inside Frog without Accessibility permission.

Closing the window keeps Frog in the menu bar. Enable **Start at login** in Settings if you want it available after a restart.

## Your settings and data

**Settings → Export / Import** moves rules, shortcuts, provider settings, and preferences between Macs. API keys stay in Keychain; text history isn’t included. Imports validate the file and back up your previous configuration. [Configuration format](docs/configuration.md).

Frog has no usage tracking or backend service. Cloud providers receive text only when you run a rule or test a connection. Local providers use the endpoint you configure. Optional history stays on your Mac and can be cleared at any time. [Privacy details](docs/privacy.md).

<details>
<summary>Settings screenshot</summary>

![Configuration import and export in Frog Settings](docs/images/frog-settings.png)

</details>

## Build from source

Requires Xcode 26+ / Swift 6.2+. Open `native/Frog.xcodeproj` and run the **Frog-macOS** scheme, or:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
bash scripts/build-app.sh
open dist/Frog.app
```

Set `FROG_UNIVERSAL=1` when building for both CPU architectures. The app is written in SwiftUI and has no third-party package dependencies.

[Build and release notes](docs/development.md) · Verification status
