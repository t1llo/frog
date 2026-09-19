# Privacy

Frog contains no analytics, telemetry, advertising, crash-reporting SDK, or usage tracking. It has no account system and doesn’t contact a Frog backend.

## Provider requests

When you run a rule, the selected text and rule instructions are sent to the provider endpoint you configured. Testing a connection sends a short test message. Cloud providers have their own data policies. For local processing, use Ollama or a compatible service on your Mac.

Frog doesn’t send requests at startup or download models. It doesn’t log selected text or API keys. Provider response bodies aren’t included in error messages. Redirects are refused, and request/response caching is disabled.

## On your Mac

- **API keys:** macOS Keychain, separate from configuration files.
- **Settings:** `~/Library/Application Support/Frog/configuration.json`.
- **History:** off by default. When enabled, original text, output, rule, provider, model, language, and time are stored locally in `history.json`. Keep up to 200 records for up to 30 days; expiry is applied when history is loaded. Delete individual entries or clear all in History.
- **Clipboard:** a successful result is placed on the system clipboard, including when automatic replacement is skipped.
- **Configuration exports/backups:** settings and rule instructions only. No keys or history. Exported files are under your control.

Turning history off stops new records, including requests already in progress. Existing records remain until cleared or expired. Clearing history during a request also prevents that request from repopulating it.

Accessibility is used to read the selection you invoke a rule on and to replace it in the original field. Frog validates focus and selection before editing; it doesn’t continuously record your typing.

The archived Go/Wails prototype is not part of the native app. Legacy data in `~/.config/frog/`, if present, is neither imported nor removed automatically.
