# Privacy

Frog contains no analytics, telemetry, advertising, crash-reporting SDK, or usage tracking. It has no account system and doesn’t contact a Frog backend.

## Provider requests

When you run a rule, the selected text and rule instructions are sent to the provider endpoint you configured. Testing a connection sends a short test message. **Find installed models** sends a model-list request to your configured Ollama or LM Studio endpoint without writing text. Cloud providers have their own data policies. For local processing, use Ollama, LM Studio or a compatible service on your Mac.

Frog doesn’t send provider requests or download model weights at startup. Explicit model downloads use the built-in Hugging Face repositories through their native SDKs; the downloads follow the model host's file/CDN redirects and cache weights locally. Text-provider requests refuse redirects and disable response caching. Frog doesn’t log selected text or API keys. Provider response bodies aren’t included in error messages.

## Transcription and built-in models

Recording starts only when you invoke an audio rule or Record. For local WhisperKit or FluidAudio/Parakeet transcription, microphone audio stays in process memory and is discarded after completion/cancellation. If the rule selects an external speech model, Frog sends the recording to that provider for transcription. The live popup shows partial text when supported and enabled. Recordings stop automatically after ten minutes. No audio files are added to history.

Adding a Hugging Face model link fetches public repository metadata and, for text models, `config.json` to inspect its format. It does not upload your text/audio or download weights. Weights download only when you press Download. Each model's information panel links to the converted weights, original model when known, and license. Parakeet inference uses local Core ML loading rather than FluidAudio's auto-download helpers.

Local cleanup uses downloaded MLX weights. A custom audio rule explicitly choosing a cloud text provider sends the transcript and instructions to that provider; raw audio is not sent. Results are copied, with optional insertion into the currently focused app after transcription, so you can change input fields while recording. Password fields are excluded when identified by Accessibility. Shared history, if enabled, saves the completed transcript and processed text before clipboard/paste delivery, under the same retention controls as writing results. If cleanup fails, the original transcript is preserved on the clipboard with an error message.

Downloaded files live in `~/Library/Application Support/Frog/Models/`. Cancelled/failed installations remove partial files. Delete installed models from Providers or Transcription. Idle models unload according to Settings; downloadable inference requires Apple silicon. Models are not included in configuration exports.

## On your Mac

- **API keys:** macOS Keychain, separate from configuration files.
- **Settings:** `~/.config/frog/config.json`; you can copy or sync this portable file yourself. Previous native settings migrate from Application Support without deleting the old file.
- **Setup:** `~/Library/Application Support/Frog/setup.json` remembers whether the local setup assistant was completed or skipped. It contains no credentials and is not exported.
- **History:** off by default. When enabled, original text, output, rule, provider, model, language, and time are stored locally in `~/Library/Application Support/Frog/history.json`. Keep up to 200 records for up to 30 days; expiry is applied when history is loaded. Delete individual entries or clear all in History.
- **Clipboard:** a successful result is placed on the system clipboard, including when automatic replacement is skipped. When an app does not expose its selection through Accessibility, Frog requests Copy and accepts only a fresh clipboard update. It also re-copies the selection before pasting to confirm the target still matches. Previous clipboard formats are restored after these temporary reads. Clipboard managers may observe those temporary copies.
- **Configuration exports/backups:** settings and rule instructions only. No keys or history. Exported files are under your control.
- **Recent errors:** Settings → Logs keeps the last 100 errors in memory for this session. Banners disappear after six seconds. Logs are not written to disk; you can explicitly copy or clear them.

**Hide history text** masks previews and details until you reveal an entry. This is a display preference, not password detection or encryption; the saved original and result remain unchanged.

Turning history off stops new records, including requests already in progress. Existing records remain until cleared or expired. Clearing history during a request also prevents that request from repopulating it.

Accessibility is used to read the selection you invoke a rule on and to replace it in the original field. Frog validates focus and selection before editing; it doesn’t continuously record your typing.

The window switcher uses Accessibility to list window titles, observe the recently focused window, and activate your chosen window. Titles, app identities and recent-window order stay in process memory; they are not written to history, logs or configuration and are never sent to a provider. A native keyboard event tap recognizes Command–Tab and switcher navigation keys; ordinary typing is passed through and is not recorded. Disabling the switcher removes that event tap. No screenshots or screen-recording permission are used.

The optional floating processing indicator shows rule/status messages without taking focus. Turn it off in **Settings → Show processing indicator**. Compatibility replacement checks input-event counters, not keystroke contents, to reject changed targets.

## Updates

Sparkle checks the GitHub release feed and downloads signed updates. Automatic checks and downloads are configurable in Settings. System profiling is disabled. GitHub receives the network requests needed to serve the feed and downloads; no text, audio or provider keys are included.
