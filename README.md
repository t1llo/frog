# Frog

Frog is a lightweight background writing assistant for **macOS and Linux**, with macOS the primary platform. Select text in another app and press a configurable hotkey to proofread it, correct spelling, improve an email, translate it, or apply a custom LLM instruction. The intended result is automatically copied to the clipboard and replaces the selection.

**Current status: incomplete prototype.** The settings UI, prompt processing, provider clients, local model tooling, and global hotkey registration exist. Automatic replacement, a menu-bar status icon, login startup, per-rule provider/model selection, and optional history still need work. The current desktop text integration uses macOS commands; Linux support is unfinished.

## Product and development documentation

- [Product requirements](docs/product.md): intended behavior and scope.
- [Implementation status](docs/status.md): what exists, known gaps, source references, and verification results.
- [Proposed work items](docs/work-items.md): four large, end-to-end work items with acceptance criteria and dependencies, pending approval and tracker setup.
- [Agent workflow](docs/agent-workflow.md): automatic same-session continuation and concise [current progress](docs/progress.md).

## Intended everyday workflow

1. Configure your own cloud API key or connect a local model service.
2. Choose a preset or create a rule with instructions, a hotkey, and a provider/model.
3. Leave Frog running in the background, starting at login.
4. Select text in an editable field and press the rule's hotkey.
5. Continue writing with the corrected or translated text inserted and available on the clipboard.
6. Open settings through the macOS menu-bar icon or Linux tray entry; optionally enable and browse history.

Cloud use requires your own provider credentials. Local services such as Ollama should work without a cloud account or cloud API key. Windows is outside the current target scope.

## Running the current prototype

The application uses Go, Wails v2, Svelte 3, TypeScript, and Vite. Install Go compatible with the `go 1.23` module directive, Node.js/npm, the Wails v2 CLI, and the [Wails platform prerequisites](https://wails.io/docs/gettingstarted/installation).

Install frontend dependencies:

```sh
cd frontend
npm ci
```

From the repository root:

```sh
wails dev
```

In **Settings**, configure and activate an OpenAI, Anthropic, or custom OpenAI-compatible remote provider. Alternatively, **Models** offers an inference-engine installer and local GGUF model downloads. These are existing code paths, not verified provider or installation guarantees.

Use the **Text** screen to try processing manually. macOS selection capture and paste currently use AppleScript/System Events and require the appropriate macOS automation/accessibility permissions. The global-hotkey result flow has known defects; see the status document.

Current default global bindings:

| Hotkey | Action |
| --- | --- |
| `Ctrl+Shift+Space` | Show Frog |
| `Ctrl+Shift+C` | Correct text |
| `Ctrl+Shift+T` | Translate using the global target language (German by default) |
| `Ctrl+Shift+S` | Summarize |

These use Control even on macOS and are editable in Shortcuts. Registration failures currently appear only in logs. Closing the window hides it; Settings includes a Quit action.

## Build and checks

From the repository root:

```sh
wails build
go test ./...
```

From `frontend/`:

```sh
npm run check
npm run build
```

`go test ./...` currently compiles packages but finds no tests. A successful build or type check does not establish that OS hotkeys, text replacement, or live providers work.

## Current storage

The prototype stores configuration in `~/.config/frog/config.json` on macOS as well as Linux. Downloaded models and the inference engine use `~/.config/frog/models/` and `~/.config/frog/bin/`. Provider API keys are currently stored in plaintext in the configuration. History storage is not implemented.
