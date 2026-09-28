# Configuration

Use **Settings → Configuration → Export / Import** to transfer rules, connections and preferences. API keys stay in Keychain; history and downloaded models are not exported. Login startup, permissions and model-storage paths belong to each Mac.

Import validates the file and backs up the previous configuration as `configuration-backup-<UUID>.json` in `~/Library/Application Support/Frog/`. Invalid files leave the existing setup untouched. Changed/new provider endpoints receive fresh Keychain identities and require their credentials again.

## Rules and models

The UTF-8 JSON format is version `1`, limited to 4 MB. Prefer exporting from Frog before editing. Quit Frog before directly modifying the live `configuration.json` file.

- `action.category` is `text`, `audio` or `application`.
- External text models use the rule's `providerID` and `model`; internal text models use `action.localTextModelID`.
- Audio uses `action.audioModelID` and, for external speech, `action.audioProviderID`.
- Audio options are `action.transcriptionLanguage`, `recordingMode` (`toggle`/`hold`), `output` (`copy`/`paste`), `showRecordingPopup` and `cleanup`.
- Cleanup uses the rule's selected text model and instructions.
- Application shortcuts store `action.applicationPath` and `action.applicationBundleID`.
- Provider `models` entries have `id`, `name` and `category` (`text`/`audio`). Missing category means text for older files.

Models are explicit per rule. `explicitRuleModels` records migration from older global defaults, preserving each rule's effective choice. `recentModels` tracks added choices for new rules. Legacy default fields remain readable for migration; they do not reroute migrated rules.

Custom Hugging Face descriptors are exported in `localModels`; weights are not. Removing a referenced source requires changing its references first.

## Preferences

History is off by default. When enabled, `historyLimit` accepts 1–200 entries and `historyRetentionDays` accepts 1–30 days. Importing shorter limits can prune history.

`applicationShortcutsEnabled` controls both application shortcuts and the window switcher. `windowSwitcherEnabled` retains the individual switcher setting. Window titles and switching history are not exported.

`preferences.workflows` includes microphone selection, mute-while-recording, cancel and shortcut-reference bindings, and `idleUnloadSeconds` (0–3600). Zero unloads internal models immediately after inference. Recording behavior belongs to each audio rule.

Appearance example, inside `preferences`:

```json
"appearance": {
  "theme": "nord",
  "mode": "dark",
  "useThemeAccent": false,
  "accentHex": "A3D8AF",
  "transparency": 0.35
}
```

Themes: `frog`, `tokyoNight`, `catppuccin`, `nord`. The interface offers Light and Dark. Accent is six hexadecimal digits without `#`; transparency ranges from 0 to 1.

## Shortcuts and compatibility

Shortcuts use macOS virtual key codes and Carbon modifier bits: Command `256`, Shift `512`, Option `2048`, Control `4096`. Record shortcuts in Frog rather than calculating these manually. Omit `hotkey` for no global shortcut.

Write translation languages in rule instructions. Legacy `{{language}}` and `targetLanguage` values remain supported. Imported providers retain Keychain access only when their identity, service type and endpoint match the existing connection.
