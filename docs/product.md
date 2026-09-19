# Frog — native macOS writing assistant

## Current scope

The user explicitly replaced the earlier cross-platform architecture with a **complete native SwiftUI app for macOS only**. The supported baseline is macOS 14 or later, on Apple silicon and Intel Macs. The old Go/Wails/Svelte code and Xcode experiment are preserved under `archive/`.

## Behavior

- Small menu-bar utility; ordinary operation does not require an open window. Menu-bar access opens a native settings window. Closing the window keeps the utility running; Quit cancels work and exits.
- Start at login using macOS login-item integration, with a user-controlled setting.
- Select text in a supported editable field in another application and press a configurable global hotkey. Apply the chosen rule using its selected LLM/provider. Automatically copy the output to the clipboard and replace the original selection.
- Never substitute stale clipboard content for a selection. If the original target changed or cannot be safely edited, preserve the result on the clipboard and explain why replacement was skipped. Show useful processing/error state without stealing focus.
- Presets: proofreading, spelling only, email polishing, translation to independently configurable languages. Users can edit/duplicate presets and create/delete custom rules with instructions, hotkeys, enablement and provider/model choices.
- Cloud providers: user-supplied keys for OpenAI, Anthropic/Claude, Gemini and configurable OpenAI-compatible endpoints. Local models: connect to Ollama or another compatible local server; no cloud key required for local-only use. Store secrets in macOS Keychain.
- Optional local history, disabled by default. Browse original/output and metadata; copy results, delete a record or clear all. Defaults: maximum 200 records, retained for 30 days. Turning recording off stops new records, including requests still in flight, but preserves existing history until deletion/expiry.
- Native settings for rules, providers, history, login startup, permissions and a manual text-processing tool. A successful external transformation needs no popup approval.
- Modern Handy-inspired visual style: a compact branded sidebar, generous spacing, rounded cards, clear typography and shortcut keycaps, with coherent light/dark appearances. Keep the interface native SwiftUI and keyboard accessible.
- Import/export portable, editable JSON configurations for rules, shortcuts, providers, models and preferences. Exclude Keychain secrets and text history. Validate imports, back up the previous file and show the replacement effect before applying it. OS permissions/login startup stay device-local.
- No analytics, telemetry, usage tracking or Frog backend. Document exactly which text is sent to user-configured providers and how optional local history works.
- A concise GitHub README with installation, usage, screenshots and downloadable preview builds. **Keep the repository private** while preparing these assets, per the user's explicit choice.

## Completion and limits

Build a real `.app` bundle, deterministic provider/persistence tests, and setup/use documentation. Record separately which native interactions and real providers have been exercised. Accessibility support differs by application; document supported behavior instead of claiming every text field can be edited. App Store distribution, Linux/Windows support, bundled model downloads, and account/subscription services are outside this native version's scope.
