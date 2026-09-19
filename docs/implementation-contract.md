# Implementation integration contract

Temporary coordination reference for the approved background-assistant implementation. Keep user-facing requirements in product.md.

## Backend / frontend

Preserve existing Wails method names where possible. Extend `ActionConfig` JSON with `providerId`, `model`, `targetLanguage`, `hotkey`, `enabled` (boolean). Empty provider/model inherits the configured default; explicit references must never silently fall back. Keep existing prompt/name/id/builtin/icon fields. `SaveAction` validates and re-registers rules. Built-ins are editable; custom rules can be deleted.

Preserve `LLMConfig` remoteProviders and activeProvider/local fields. Add provider types `gemini` and `ollama`. API keys returned to frontend are empty; add `hasApiKey` for saved keys. Empty key on save retains saved key; explicit `clearApiKey` removes it. Secrets live in OS credential storage.

New methods:

- `TestProvider(provider RemoteProviderConfig) (string, error)` verifies the supplied connection/model, using its stored secret if API key is empty.
- `GetPreferences() Preferences`, `SavePreferences(Preferences) error`: JSON `startAtLogin`, `historyEnabled`, `historyLimit` (default 200), `historyRetentionDays` (default 30).
- `GetHistory() []HistoryEntry`, `DeleteHistory(id string) error`, `ClearHistory() error`: entries `id`, `timestamp` (ISO string), `originalText`, `processedText`, `actionId`, `actionName`, `provider`, `model`, `targetLanguage`.
- `GetHotkeyStatus() []HotkeyStatus`: `id`, `hotkey`, `error` (empty means registered).
- `GetDesktopStatus() map[string]string`: platform integration diagnostics for settings.
- `CancelProcessing()`: cancel current processing.

Events: `notification` with `type` (`error`, `warning`, `info`, `success`) and `message`; `processing` with `busy` boolean; `history:changed`; `config:changed`. Frontend must unsubscribe on destruction and render errors from Go string rejections as well as Error objects.

## Desktop / backend

Platform owner supplies these packages without editing app.go:

- `keysim.CaptureSelection(ctx context.Context) (*keysim.Selection, error)`; selection has `Text string` and `Replace(ctx context.Context, text string) error`. Capture detects no new selection. Replace writes the result to clipboard then verifies original target/selection before paste; on invalid target it retains result and returns an actionable error. Existing helper functions remain compatible.
- `desktop.Start(onShow func(), onQuit func())`, `desktop.Stop()`, `desktop.Notify(title, message string)`, `desktop.SetStartAtLogin(enabled bool) error`, `desktop.Status() map[string]string`. Startup activation argument is `--background` (handled by main.go).
- Global hotkey manager: keep Register(ctx, bindings), add `Status() []globalhotkey.Status` with JSON id/hotkey/error and `Validate(string) error`. Platform-specific modifiers and robust conflict reporting. Trigger after key release to avoid interfering with simulated copy.
- Clipboard retains `ReadText()` and `Write(string)` with no whitespace trimming and platform-specific implementation.

Platform owner edits main.go to wire desktop startup, show/quit callbacks and hidden launch (can call existing `app.Quit`). Backend startup/shutdown handles desktop.Start/Stop and desktop notifications through methods above. Coordinate main.go so desktop.Start is called only once (backend owns call).

## Ownership

- Backend: app.go, internal/config, internal/llm, internal/textproc, new history/credential packages and tests.
- Desktop: main.go, internal/keysim, internal/clipboard, internal/globalhotkey, new internal/desktop and tests; platform packaging notes.
- Frontend: frontend/src and frontend bridge declarations as needed; parent regenerates Wails bindings after merge.
- Integrator: module dependency reconciliation, bindings, builds/CI, documentation, final review and verification. Dependencies may be edited by backend/desktop owners but must be reconciled on merge.
