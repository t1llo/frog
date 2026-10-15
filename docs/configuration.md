# Configuration

Frog uses two portable files in **`~/.config/frog/`**:

- **`config`**: UTF-8 `key = value` settings, features, shortcuts, model defaults and theme colors.
- **`config.json`**: versioned rules, connections, custom model definitions and additional/internal fields. Preferences represented in `config` are omitted here.

Use **Settings → Configuration → Open config**, save your edits, then **Reload**. Valid changes apply immediately, including theme, feature lifecycle, shortcuts, history limits and model idle policy. Finish an active request or recording before reloading. A running Stay awake session must be restored before disabling that feature. Model defaults do not override explicit per-rule selections.

UI edits update the same files, preserving comments, ordering, whitespace and unchanged value spellings. If either file (or its symlink destination) changed since Frog loaded it, UI saves stop with a **Reload** message rather than overwriting those edits. Invalid reloads keep the running configuration and files untouched; errors appear in the banner and Settings → Logs. There is no automatic file watcher.

## Syntax

```ini
# Appearance follows macOS; the preset supplies every unspecified color.
appearance = system
theme = tokyoNight
transparency = 0.15
popup-transparency = 0

feature.command-bar = true
feature.usage = true
feature.scripts = false
shortcut.command-bar = ctrl+alt+space
shortcut.clipboard = cmd+shift+v

history-enabled = false
history-limit = 100
model-idle-seconds = 300

palette.dark.background = #1A1B26
palette.dark.sidebar = #16161E
palette.dark.surface = #24283B # cards and panels
palette.dark.text = #C0CAF5
palette.dark.accent = #7AA2F7
palette.light.accent = #34548A
```

Keys are case-sensitive. Booleans are `true`/`false`; numbers use a decimal point. A `#` starts a comment, except the initial `#` of a color value. Strings containing `#` or quotes must be JSON double-quoted (`"a # value"`). Duplicate keys, unknown keys and invalid values are errors with line numbers. Remove an assignment to use its default. The file Frog first writes lists every value; later saves from the app add a removed assignment back only once its value differs from the default. Blank lines and comments are preserved. Both files have a 4 MB limit.

### General and model settings

| Key | Values / default |
| --- | --- |
| `language` | `system`, `en`, `de`; default `system`. Reserved: Frog's interface is English and the value has no effect. It stays accepted so that older files keep loading |
| `writing-indicator` | Boolean; default `true` |
| `history-enabled`, `history-hide-text` | Boolean; default `false` |
| `history-limit` | 1–200; default 200 |
| `history-retention-days` | 1–30; default 30 |
| `model-idle-seconds` | 0–3600; default 120; 0 unloads after inference |
| `audio-model` | Legacy default: an audio ID in the built-in/custom model catalog; default `whisper-large-v3-turbo-626mb` |
| `cleanup-model` | Legacy default: a local text model ID; default `qwen-0.6b` |
| `text-model` | Legacy default: an optional local text model ID |
| `text-source` | Legacy default: `provider` or `frog`; follows the local text default when omitted |
| `transcription-language` | `auto`, `en`, `de`, `fr`, `es`, `it`, `pt`, `nl`, `pl`, `uk`, `ru`, `ja`, `zh`, `ko`, `ar`, `hi`, `tr` |
| `recording-mode` | `toggle` or `hold`; default `toggle` |
| `recording-output` | `copy` or `paste`; default `copy` |
| `recording-popup` | Boolean; default `true` |
| `recording-mute-audio` | Boolean; default `false`. An output that cannot be muted does not stop the recording; Frog says so once |
| `microphone` | Optional persistent UID of the audio input, as Settings and the recording popup save it; omit for system default. A device number saved by an earlier version names no input and means system default until a microphone is chosen again |

Recording values are defaults/legacy compatibility; each audio rule can explicitly select its own behavior. The four model settings date from before each rule chose its own model: they give rules from an older configuration their first selection and never change a rule's own choice. History is local and off by default. Lowering retention limits may prune existing history. Hiding history masks previews, not stored text. Login startup, permissions and model-storage paths remain machine-local.

### Features

Each `feature.<name>` takes a boolean.

Enabled by default:

- `writing`
- `dictation`
- `application-shortcuts`
- `window-switcher`
- `stay-awake`

Disabled by default:

- `clipboard`
- `command-bar`
- `usage`
- `snippets`
- `scratchpad`
- `shelf`
- `scripts`
- `quick-actions`
- `menu-bar`
- `system-monitor`
<!-- slot: explain -->
<!-- slot: windows -->
<!-- slot: cleaner -->
<!-- slot: emoji-picker -->
<!-- slot: processes -->
<!-- slot: color-picker -->
<!-- slot: quicklinks -->

Older installations retain their existing shortcut/window enablement semantics during migration. `hidden-sidebar-items` hides navigation entries without disabling the feature; use a JSON list of stable feature IDs, for example `["usage", "scripts", "commandBar"]`. Multiword feature **keys** are kebab-case; IDs in this list are camelCase:

- `applicationShortcuts`
- `windowSwitcher`
- `stayAwake`
- `commandBar`
- `quickActions`
- `menuBar`
- `systemMonitor`
<!-- slot: explain -->
<!-- slot: windows -->
<!-- slot: cleaner -->
<!-- slot: emoji-picker -->
<!-- slot: processes -->
<!-- slot: color-picker -->
<!-- slot: quicklinks -->

### Global shortcuts

`shortcut.rules`, `shortcut.cancel-recording`, `shortcut.clipboard`, `shortcut.command-bar` and `shortcut.window-switcher` accept readable physical macOS key names:

```ini
shortcut.rules = ctrl+alt+k
shortcut.cancel-recording = ctrl+escape
```

Modifiers: `ctrl`, `alt`, `shift`, `cmd`, each at most once. At least `ctrl`, `alt` or `cmd` is required. Keys include letters, digits, `space`, `tab`, `return`, `escape`, `delete`, `forward-delete`, the arrows `left`, `right`, `up`, `down`, `f1`–`f12`, `home`, `end`, `page-up`, `page-down`, punctuation names (`comma`, `period`, `slash`, `semicolon`, `quote`, `minus`, `equal`, `grave`, `backslash`, `left-bracket`, `right-bracket`) and `keycode-<number>` for other macOS virtual keys. Names refer to physical US-layout positions, independent of the active keyboard layout. Frog's recorder shows layout-aware labels.

Omit rules/cancel shortcuts for no binding. Clipboard defaults to `cmd+shift+v`; command bar defaults to `ctrl+alt+space`; the window switcher defaults to `cmd+tab`. Disable the corresponding feature to stop its default binding. Escape always cancels recording. Reserved system/clipboard combinations and conflicting enabled shortcuts are rejected. Individual rule shortcuts remain in JSON (virtual key code plus Carbon modifier bits: Command 256, Shift 512, Option 2048, Control 4096).

### Themes and semantic colors

`appearance`: `system`, `light`, `dark`. `theme`: `minimal`, `frog`, `tokyoNight`, `catppuccin`, `nord`, `gruvbox`, `dracula`, `rosePine`, `solarized`, `everforest`, `graphite`. Without a `theme` line Frog uses `minimal`, a gray and white theme with a gray accent.

Every preset supplies a coordinated light and dark palette. Override any of these roles independently with `palette.light.<role>` / `palette.dark.<role>`:

| Role | Used for |
| --- | --- |
| `background` | Main window canvas |
| `sidebar` | Navigation background |
| `surface` | Cards, management areas and popup panels |
| `inset` | Inputs and inset controls |
| `border` | Dividers and outlines |
| `text` | Primary text |
| `muted` | Secondary text and symbols |
| `accent` | Highlights, selection, active controls |
| `on-accent` | Nothing at present; still accepted so older files keep loading |
| `good` | Comfortable status: usage under pace |
| `warning` | Status worth watching: usage ahead of pace, high load, notices |
| `critical` | Status at the limit: a nearly used plan window, very high load, a nearly full disk |

Colors are six RGB hex digits, optionally prefixed with `#`. Overrides inherit all unspecified roles from the selected theme. `accent` sets a single custom accent for both modes; use `theme-accent = false` to choose it explicitly. `theme-accent = true` uses the preset accent. Per-mode palette accents take precedence over both. With no explicit `theme-accent`, Frog preserves the old custom accent behavior. Changing the accent in Settings clears only palette accent overrides; choosing a preset in Settings resets all palette overrides. Editing the `theme` key preserves your explicit overrides.

`transparency` and `popup-transparency` independently range from 0 (opaque) to 1. The whole window and all Frog popups use a real, active native `NSVisualEffectView` with behind-window backdrop blur; text is never blurred or faded. Popup fields/cards use their popup setting, independent of the main window. Inset controls retain a stronger tint for readability. Visible pixels blend the palette with the blurred material. Native macOS controls, system status colors and content images retain their platform/content colors.

**Reduce Transparency** or **Increase Contrast** in macOS accessibility settings makes Frog surfaces opaque without changing your saved values. Increased Contrast also strengthens panel outlines. The `frog` theme keeps its black surfaces and green accent in dark mode.

### Menu-bar organization

Enable with `feature.menu-bar = true`. Portable settings:

- `menubar.auto-hide`: boolean, default `true`.
- `menubar.auto-hide-seconds`: 1–3600 seconds, default 10; fractions are supported.
- `menubar.start-collapsed`: boolean, default `false`.
- `menubar.permanently-hidden-section`: boolean, default `false`.
- `menubar.hover-to-reveal`: boolean, default `false`.
- `menubar.hotkey`: optional readable shortcut, such as `ctrl+alt+m`; unassigned by default.

macOS status-item positions stay on each Mac.

### Portable usage display

- `usage.provider`: `Claude` or `OpenAI`.
- `usage.range`: `24h`, `7d`, `30d`.
- `usage.metric`: `API cost`, `Input`, `Output`, `Cache write`, `Cache read`.
- `usage.all-devices`: legacy boolean retained for configuration round trips. OpenAI
  activity now always combines available account totals and local tool activity;
  this setting no longer changes the chart.
- `usage.login-source`: `Automatic`, `Claude Code`, `Claude Desktop`, `OpenCode`, `Pi`. `Claude Desktop` reads the limits the Claude app saves locally and makes no request; `Automatic` shows whichever reading is newer.

These fields select the display and login-source preference only. Accounts, tokens, readings and polling state are not configuration payloads.

<!-- slot: usage -->

Several Claude accounts on one Mac, such as two Claude app profiles:

- `usage.claude-accounts`: boolean, default `false`. Reads the saved limits of every Claude
  account Frog finds on this Mac and shows each of them; while it is on, the login source
  menu is hidden and each account is read on its own.
- `usage.claude-accounts-view`: `each` (default) shows every account's limits side by side;
  `combined` shows one value per limit over the included accounts, weighted by plan size
  when every plan is known.
- `usage.claude-accounts-menu-bar`: `session` (default) or `week`, the limit the menu bar
  item shows for each account while the view is `each`.

Accounts, folders and labels stay on this Mac and are not part of the configuration.

<!-- slot: explain -->
<!-- slot: windows -->
<!-- slot: cleaner -->
<!-- slot: command-bar -->
### Command bar

- `command-bar.learn-choices`: Learn from your choices: rows you pick for what you type are listed a bit higher. Default false. Stored in `~/Library/Application Support/Frog/command-choices.json`, never in this folder.

<!-- slot: clipboard -->
<!-- slot: snippets -->
<!-- slot: emoji-picker -->
<!-- slot: processes -->
<!-- slot: color-picker -->
<!-- slot: quicklinks -->

## Migration, sync and JSON interchange

On first use without a text `config`, a valid legacy `config.json` is backed up verbatim as `config-legacy-backup-<UUID>.json`, then its settings are written into `config`. Complex data remains in `config.json`. The previous native `~/Library/Application Support/Frog/configuration.json` is also supported and is left intact; it is read only until `config.json` has existed on this Mac, and after that only through Import. A recognized prototype destination is backed up before replacing it. Invalid or unsupported files are not silently overwritten; repair them or explicitly import a valid export.

Sync **both** `config` and `config.json`, for example:

```sh
chezmoi add ~/.config/frog/config ~/.config/frog/config.json
```

A `config` without `config.json` starts a new configuration on a Mac where Frog has not used `config.json` before; the first save adds it. Once `config.json` has existed there, Frog notes this in `~/Library/Application Support/Frog`, and a `config.json` that goes missing is an error that leaves both files unchanged: restore it, import a configuration, or remove `config` as well to start again.

Frog follows file/directory symlinks and atomically replaces their resolved file destinations, leaving links intact. New files use mode 0600; existing parent-directory permissions are not changed. Each file is written atomically; this is not a cross-file transaction or a distributed sync/merge service. Coordinate changes between Macs and Reload after `chezmoi apply`. Backups are local recovery copies; they need not be synced. Frog keeps the five newest of each kind and removes older ones when it writes another; a migration or import that cannot be written leaves none.

**Settings → Configuration → Export** creates one complete, backwards-compatible version-1 JSON document including the effective text preferences, all palette overrides and usage display settings. **Import** validates that document and writes both local files, backing up existing JSON and text as `configuration-backup-<UUID>.json` / `.conf`. Comments in valid text documents are preserved; unreadable text remains in the backup. Use Import for a single-file export; the split `config.json` alone is not a complete export. API keys, history, downloads and setup progress are never exported. Changed/new imported connections receive fresh credential identities; matching identities, service types and endpoints keep existing credentials.

Unknown JSON extension fields are retained, including fields inside identified rules, connections and models. Supported settings edited or removed in the UI take precedence; deleting a known item does not resurrect it from extension data. Custom Hugging Face descriptors remain in `localModels`, without weights.

## Rules and connections in JSON

- `action.category`: `text`, `audio`, `application`, `window`, `system`.
- External text models: rule `providerID` and `model`; internal text: `action.localTextModelID`.
- Audio: `action.audioModelID`, plus `action.audioProviderID` for external speech.
- Audio options: `transcriptionLanguage`, `recordingMode`, `output`, `showRecordingPopup`, `cleanup` in `action`. Cleanup uses that rule's selected text model and instructions.
- Applications: `action.applicationPath` and `action.applicationBundleID`; windows: `action.windowAction`; system: `action.systemAction`. Record their shortcuts in the app.
- `action.textOutput`: `replace` (default) or `panel` for text rules. A `panel` rule answers in the Explain panel instead of replacing the selection. Frog versions before Explain ignore this field and treat the rule as a Writing rule.
- Provider `models`: entries with `id`, `name`, `category` (`text`/`audio`); a missing category defaults to text for older files.

Models are explicit per rule. `explicitRuleModels` records migration from older global defaults; `recentModels` tracks choices for new rules. `explainPresetVersion` records that the Explain rule was created once; deleting the rule does not bring it back. Legacy global defaults remain readable without rerouting migrated rules. Removing a custom model that a rule still uses requires changing that rule first; an `audio-model`, `cleanup-model` or `text-model` setting that names it returns to its default. Legacy `{{language}}` and `targetLanguage` translation fields remain supported.
