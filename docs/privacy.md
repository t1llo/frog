# Privacy

Frog contains no analytics, telemetry, advertising, crash-reporting SDK, or usage tracking. It has no account system and doesn’t contact a Frog backend.

## Provider requests

When you run a rule, the selected text and rule instructions are sent to the provider endpoint you configured. Testing a connection sends a short test message. **Find installed models** sends a model-list request to your configured Ollama or LM Studio endpoint without writing text. Cloud providers have their own data policies. For local processing, use Ollama, LM Studio or a compatible service on your Mac.

Frog doesn’t send requests at startup or download models. It doesn’t log selected text or API keys. Provider response bodies aren’t included in error messages. Redirects are refused, and request/response caching is disabled.

## On your Mac

- **API keys:** macOS Keychain, separate from configuration files.
- **Settings:** `~/Library/Application Support/Frog/configuration.json`.
- **History:** off by default. When enabled, original text, output, rule, provider, model, language, and time are stored locally in `history.json`. Keep up to 200 records for up to 30 days; expiry is applied when history is loaded. Delete individual entries or clear all in History.
- **Clipboard:** a successful result is placed on the system clipboard, including when automatic replacement is skipped. When an app does not expose its selection through Accessibility, Frog requests Copy and accepts only a fresh clipboard update. It also re-copies the selection before pasting to confirm the target still matches. Previous clipboard formats are restored after these temporary reads. Clipboard managers may observe those temporary copies.
- **Configuration exports/backups:** settings and rule instructions only. No keys or history. Exported files are under your control.

Turning history off stops new records, including requests already in progress. Existing records remain until cleared or expired. Clearing history during a request also prevents that request from repopulating it.

Accessibility is used to read the selection you invoke a rule on and to replace it in the original field. Frog validates focus and selection before editing; it doesn’t continuously record your typing.

The window switcher uses Accessibility to list window titles, observe the recently focused window, and activate your chosen window. Titles, app identities and recent-window order stay in process memory; they are not written to history, logs or configuration and are never sent to a provider. A native keyboard event tap recognizes Command–Tab and switcher navigation keys; ordinary typing is passed through and is not recorded. Disabling the switcher removes that event tap. No screenshots or screen-recording permission are used.

The optional floating processing indicator shows rule/status messages without taking focus. Turn it off in **Settings → Show processing indicator**. Compatibility replacement checks input-event counters, not keystroke contents, to reject changed targets.

The archived Go/Wails prototype is not part of the native app. Legacy data in `~/.config/frog/`, if present, is neither imported nor removed automatically.
