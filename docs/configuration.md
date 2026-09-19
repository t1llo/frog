# Configuration files

Use **Settings → Export…** to save `Frog-configuration.json`. Use **Import…** on another Mac, or edit the file and import it again. The app shows the number of rules and providers before replacing your setup.

## What moves

- Rules: names, instructions, enabled state, shortcuts, provider/model overrides, and target languages.
- Providers: service type, name, API endpoint, and default model.
- The default provider and history preferences.

API keys and text history are never exported. Login startup and macOS permissions belong to each Mac and must be configured separately. Frog doesn’t sync files or upload configurations to a service.

## Import behavior

Import replaces the current configuration. Before writing it, Frog checks the file version, references, shortcuts, endpoints, and preference limits. An invalid file leaves your setup untouched. Shortcuts already occupied by other apps are reported in Rules after import.

The previous settings file is backed up as `configuration-backup-<UUID>.json` in `~/Library/Application Support/Frog/`. You can import that backup to undo a change. Explicit import can also recover a malformed settings file while preserving its original bytes in the backup.

An existing provider keeps its Keychain identity only if its ID, service type, and endpoint still match. New or changed connections get a fresh identity and need their API key entered again. Import doesn’t delete saved Keychain items. This prevents an imported endpoint from silently inheriting a different connection’s key.

History records are separate. Imported recording/retention preferences apply to them: recording can turn on or off, and shorter retention or entry limits can prune existing records. The confirmation dialog explains this before import.

## Format

The format is UTF-8 JSON, version `1`, limited to 4 MB. This minimal example uses Ollama and one proofreading rule:

```json
{
  "version": 1,
  "providers": [
    {
      "id": "070BC5A9-29DD-42E7-A4E5-5849C542DF11",
      "name": "Ollama",
      "kind": "ollama",
      "endpoint": "http://localhost:11434",
      "model": "llama3.2"
    }
  ],
  "defaultProviderID": "070BC5A9-29DD-42E7-A4E5-5849C542DF11",
  "rules": [
    {
      "id": "D6D41870-A571-4978-98B0-E8AF21E434D0",
      "name": "Proofread",
      "instructions": "Fix grammar and spelling. Return only the corrected text.",
      "model": "",
      "targetLanguage": "",
      "hotkey": { "keyCode": 8, "modifiers": 4608 },
      "enabled": true,
      "preset": false
    }
  ],
  "preferences": {
    "historyEnabled": false,
    "historyLimit": 200,
    "historyRetentionDays": 30
  }
}
```

Provider kinds: `openAI`, `anthropic`, `gemini`, `ollama`, `compatible`. Cloud services require HTTPS; localhost model services can use HTTP. Credentials, query parameters, and fragments aren’t allowed in endpoint URLs.

Omit a rule’s `providerID` to use the default provider; an empty `model` uses that provider’s model. Instructions may contain `{{language}}`, replaced with `targetLanguage`.

Shortcuts use macOS virtual key codes and Carbon modifier bits. The example is Control + Shift + C (`4096 + 512`). Command is `256`; Option is `2048`. The easiest way to set shortcuts is to record them in Frog and export the result. Omit `hotkey` for a rule without a global shortcut.

The live file is `~/Library/Application Support/Frog/configuration.json`. Quit Frog before editing it directly; importing is preferable while the app is running.
