# Frog

[![Build](https://github.com/t1llo/frog/actions/workflows/native.yml/badge.svg?branch=main)](https://github.com/t1llo/frog/actions/workflows/native.yml)
[![Release](https://img.shields.io/github/v/release/t1llo/frog)](https://github.com/t1llo/frog/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)

A Mac app that lives in your menu bar and replaces ten small Mac apps.

**[Website](https://frog.beffa.xyz/)** · **[Download](https://github.com/t1llo/frog/releases/latest)**

![Frog: ten Mac apps, one menu bar. The Features page switches tools such as Writing, Dictation and Shortcuts on and off.](docs/media/frog-preview.jpg)

[![Native Frog walkthrough: Features, Mr. Usage, snippets, notes, Tokyo Night and clipboard](docs/media/frog-readme-demo.gif)](docs/media/frog-toolkit.mp4)

## Tools

| | |
| --- | --- |
| **Writing & dictation** | Local speech models, custom rewrite rules, connected providers and installed AI tools. |
| **Explain** | Select text and read an answer in a panel next to it: any model, follow-up questions, nothing replaced; save answers to Obsidian or any Markdown folder; an optional bubble that appears when you select text. |
| **Command bar & windows** | App/file and macOS settings search, calculations, conversions, window switching and the Windows page. |
| **Windows** | Drag-to-snap zones, a layout picker, ⌃⌥ shortcuts on request, gaps and a cheat sheet. |
| **Clipboard & documents** | Searchable clipboard, snippets, Markdown notes, file/link shelf and saved scripts. |
| **Mr. Usage** | Claude/OpenAI limits, token charts and estimated costs; combined OpenCode + Codex activity. |
| **Menu bar & Stay awake** | Hide/reveal icons, auto-hide, timed awake sessions and low-battery stop. |
| **System monitor** | CPU/GPU charts, disk capacity and I/O, battery power and thermal status in an optional Frog menu view. |
| **Personalization** | Eleven themes including Tokyo Night, transparency, editable config files and optional local statistics. |

Enable tools individually in **Features**. No Frog account. No telemetry.

The command bar can learn from your choices, so rows you pick often for what you type
are listed a bit higher; it is off by default and stays on your Mac.
Window switcher and Clipboard shortcuts are configured in their Features cards;
clipboard entries live in **History**. **Shortcuts** groups Application, Windows
and Other actions. Window layouts live on the **Windows** page when it is on.
In the window switcher, type to filter; the query shows at the top.
Give **Show shortcuts** a key and hold it to see every shortcut, grouped by page.
Enable **System monitor** to switch between **Frog** and **System** in the menu-bar
popup. While it is on, CPU and GPU load are recorded every few seconds, so the graph
already holds the last ten minutes when you open it. Disk and power are read only
while the view is visible; unsupported metrics show as unavailable.
Several Claude accounts: Frog finds a second Claude app profile and can show A and B
side by side or combined in **Mr. Usage**. Off by default.

## Install

**[Download the latest release](https://github.com/t1llo/frog/releases/latest)**, open the DMG (or unzip the ZIP), and move **Frog.app** to **Applications**.

macOS 14+ · Apple silicon and Intel · Built-in model inference requires Apple silicon.

Local models stay on your Mac; connected providers use their own services. API keys live in Keychain. Permissions are feature-specific. **[Privacy](docs/privacy.md)**

## Build

Requires Xcode with Swift 6.3+ (CI uses Xcode 27).

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test -c release
make build
open dist/Frog.app
```

See [Development](docs/development.md) for signing and packaging.

## Guides

[Configuration and themes](docs/configuration.md) · [Providers](docs/providers.md) · [Local models](docs/local-model-sources.md) · [Installed AI tools](docs/local-tool-providers.md) · [Mr. Usage](docs/usage-integration.md) · [Statistics](docs/statistics.md) · [Stay awake](docs/stay-awake.md) · [Verification](docs/verification.md)

## License

Copyright © 2026 Tillo Beffa. Frog is free software under the [GNU General Public License](LICENSE), version 3 or later.
