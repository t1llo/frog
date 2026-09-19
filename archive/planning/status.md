# Implementation status

Snapshot: 2026-09-19. Based on the current working tree, including existing uncommitted changes. This is a source inventory plus compilation/static checks, not a live desktop or provider certification.

## Summary

The runnable application entry point is Go/Wails with a Svelte frontend. It already has substantial prototype functionality, but does not yet deliver the background select → hotkey → replace workflow specified in [the product requirements](product.md).

| Capability | Current evidence | Remaining work |
| --- | --- | --- |
| Settings window | Wails window and Text, Models, Shortcuts, Settings views | Organize around rules and background operation |
| Prompt processing | Built-in correct, email, outline, summarize, translate actions; template expansion; manual text UI | Separate spelling/proofreading presets and verify behavior |
| Custom actions | Create/save/delete prompt definitions in Settings and backend | Unified rule editor with hotkey, language, provider/model selection |
| Global hotkeys | Default bindings, recorder, persistence and registration | Reliable validation, conflicts, custom rule assignment, platform support |
| Selected text | macOS copy simulation and clipboard capture | Reliable capture, stale clipboard detection, Linux integration |
| Automatic result application | Paste and copy helpers exist; hotkey handler emits a popup event | Automatically copy and replace; preserve original target and handle focus changes |
| Cloud providers | OpenAI-compatible and Anthropic HTTP clients, API-key settings | Live verification, Gemini setup, robust errors and per-rule routing |
| Local models | GGUF downloads and managed llama-server lifecycle/UI | Explicit Ollama setup and verification; resource lifecycle |
| Per-rule model/provider | One active provider shared by all processing | Persist and resolve provider/model per rule |
| Translation languages | One global target for hotkey translation | Multiple independent language-specific rules/hotkeys |
| Background window lifecycle | Close hides the window; Settings Quit sets quitting flag | Status icon, reliable quit paths, hidden login startup |
| Login startup | No implementation found | macOS/Linux integration and settings |
| Menu-bar/tray icon | Conventional application menu only | Persistent macOS status item and Linux tray access |
| History | No storage, settings or history view found | Optional recording, browsing, copying and deletion |
| Linux | Wails foundation; desktop text helpers use macOS commands | Platform-specific hotkeys, capture/paste, tray, startup, packaging and verification |

## Concrete gaps in the current flow

### Hotkey results are not automatically applied

In `app.go`, the text-hotkey callback captures text, calls the processor, and emits `popup:result`. It does not call clipboard writing or replacement on success. The existing replacement helpers are exposed for manual popup buttons.

The popup contract is also inconsistent:

- The backend sends `actionID`, while `frontend/src/App.svelte` expects `actionName`.
- `App.svelte` mounts `PopupResult` without setting its `visible` prop, which defaults to false and gates rendering.
- The parent listens for `close`, but `PopupResult.svelte` dispatches `dismiss`.
- A background result does not show the hidden Wails window; the popup is an in-window component.
- Backend `notification` events have no corresponding frontend listener in the inspected source; `Notification.svelte` only observes the frontend notification store.

These source-level mismatches explain why successful processing can fail to yield a useful visible result. They have not been reproduced in a live desktop session during this inventory.

### Selection and paste assume macOS and the current focus

`internal/keysim/keysim.go` uses `osascript`, `pbpaste`, `pbcopy`, and fixed delays. It restores the previous clipboard after capture but does not prove that copy produced a new selection. If copying does nothing, old clipboard text can be processed. Paste targets whichever application currently has focus; no original application/selection tracking exists.

`internal/clipboard/clipboard.go` also uses macOS commands. Its `ReadText` trims whitespace. Its separate `Read` helper incorrectly tries `pbcopy` before `pbpaste`; the frontend clipboard-read binding uses `ReadText`, not that helper.

### Rule configuration is split and incomplete

`internal/config/config.go` stores prompt actions separately from global hotkeys and has no provider/model or target-language fields on actions. `internal/textproc/textproc.go` uses a single shared provider. `ShortcutsManager.svelte` edits existing text bindings but has no complete create-and-bind custom text-rule flow.

Hotkey parsing/registration errors in `internal/globalhotkey/globalhotkey.go` are logged rather than returned to settings. A successful configuration save therefore does not prove that a hotkey registered. Its modifier mapping uses macOS-specific `ModOption`/`ModCmd` names and needs platform-aware implementation and Linux compilation verification.

### Provider setup is a prototype

`internal/llm/llm.go` contains OpenAI-compatible chat-completion and Anthropic message clients. `Settings.svelte` exposes OpenAI, Anthropic, and custom endpoint types. There is no explicit Gemini or Ollama setup flow. A compatible custom endpoint might work, but neither provider was exercised here.

`app.go` does not consistently clear the prior active provider when a new configuration cannot initialize a replacement. Hotkey processing calls the processor directly, bypassing the readiness checks used by manual `ProcessText`. These paths need a common execution contract so a rule cannot silently use stale provider state.

Configuration serializes API keys into JSON and writes it with mode `0644`. Credential storage and errors should be addressed alongside provider setup.

### Desktop lifecycle needs completion

`main.go` creates an application menu, not a menu-bar status icon. The default startup opens a window. `app.go` hides on close and offers a `Quit` method that sets `isQuitting`; the application menu instead invokes the Wails quit function directly. Verify and unify close/quit behavior when implementing the background lifecycle.

## Repository map

- `main.go`: desktop window, application menu, Wails lifecycle hooks.
- `app.go`: frontend bindings, configuration orchestration, hotkey callbacks, provider lifecycle.
- `internal/config/`: persisted settings and built-in defaults.
- `internal/textproc/`: action selection and prompt expansion.
- `internal/llm/`: provider HTTP clients, model registry/downloads, managed local server.
- `internal/globalhotkey/`, `internal/keysim/`, `internal/clipboard/`: OS interaction.
- `internal/shortcuts/`: extra macOS application-launcher functionality.
- `frontend/src/`: Svelte views and frontend state.
- `frontend/wailsjs/`: generated Wails bindings.
- `froggy/`: separate Xcode project with existing staged/deleted work; it is not the entry point configured by Wails. Its intended role remains unconfirmed.

## Verification performed

| Check | Result |
| --- | --- |
| `go test ./...` on the current macOS environment | Passed; every package reports no test files |
| `npm run check` in `frontend/` | 0 errors, 3 warnings, 6 hints |

Warnings concern label association in Shortcuts, keyboard accessibility in Settings, and an unused popup property. Hints concern unused declarations.

Not exercised: live API calls, model downloads/inference, global hotkeys, accessibility permissions, actual clipboard replacement, packaged application build, login lifecycle, Linux build or desktop operation. These checks remain acceptance work; passing static checks is not evidence of end-to-end completion.
