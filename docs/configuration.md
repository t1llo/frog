# Configuration

Use **Settings → Configuration → Export / Import** to transfer rules, connections and preferences. API keys stay in Keychain; history and downloaded models are not exported. Login startup, permissions and model-storage paths belong to each Mac.

The standard file is **`~/.config/frog/config.json`**. Copy a native Frog export there, or sync that file between Macs. Quit Frog before replacing it and reopen to load changes. Settings shows the path and a Finder shortcut. Keys, history, downloaded weights and setup progress remain machine-local.

Existing native settings migrate automatically from `~/Library/Application Support/Frog/configuration.json`, leaving the old file intact. If the destination contains the recognized older prototype format, it is backed up before migration. An existing native config takes precedence; malformed or unknown files are not silently replaced.

Import validates the file and backs up the previous configuration as `configuration-backup-<UUID>.json` beside the config. Invalid files leave the existing setup untouched. Changed/new provider endpoints receive fresh Keychain identities and require their credentials again.

## Rules and models

The UTF-8 JSON format is version `1`, limited to 4 MB. Prefer exporting from Frog before editing. A copied config preserves provider identifiers; re-enter keys on a new Mac. Coordinate sync so two Macs do not overwrite each other's changes; Frog does not merge simultaneous edits.

- `action.category` is `text`, `audio` or `application`.
- External text models use the rule's `providerID` and `model`; internal text models use `action.localTextModelID`.
- Audio uses `action.audioModelID` and, for external speech, `action.audioProviderID`.
- Audio options are `action.transcriptionLanguage`, `recordingMode` (`toggle`/`hold`), `output` (`copy`/`paste`), `showRecordingPopup` and `cleanup`.
- Cleanup uses the rule's selected text model and instructions.
- Application shortcuts store `action.applicationPath` and `action.applicationBundleID`.
- Window shortcuts store `action.windowAction`. All 15 window actions start disabled with no assigned shortcut. Use **Shortcuts → Applications / Windows** to record one inline; recording enables that action automatically. Assigned shortcuts appear first, including disabled assignments. Installed applications are listed automatically, but only configured shortcuts are saved.
- Provider `models` entries have `id`, `name` and `category` (`text`/`audio`). Missing category means text for older files.

Models are explicit per rule. `explicitRuleModels` records migration from older global defaults, preserving each rule's effective choice. `recentModels` tracks added choices for new rules. Legacy default fields remain readable for migration; they do not reroute migrated rules.

Custom Hugging Face descriptors are exported in `localModels`; weights are not. Removing a referenced source requires changing its references first.

## Preferences

History is off by default. When enabled, `historyLimit` accepts 1–200 entries and `historyRetentionDays` accepts 1–30 days. Importing shorter limits can prune history. `hideHistoryText` masks history previews and details until you reveal an entry; it does not change the stored text or detect passwords.

`applicationShortcutsEnabled` controls application shortcuts, window actions and the window switcher. `windowSwitcherEnabled` retains the individual switcher setting. Window titles and switching history are not exported.

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
