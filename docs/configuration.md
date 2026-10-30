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
- `scratchpad`
- `scripts`
- `menu-bar`
- `system-monitor`
- `explain`
- `windows`
- `cleaner`
- `phone`
- `plugins`

`scratchpad` is Notes. Snippets and the shelf became part of Notes in 1.0.39, and Quick actions became command bar rows: a file that still sets `snippets`, `shelf` or `quick-actions` loads, turns Notes on when `snippets` or `shelf` was on, and leaves those keys out the next time Frog saves it.

Older installations retain their existing shortcut/window enablement semantics during migration. `hidden-sidebar-items` hides navigation entries without disabling the feature; use a JSON list of stable feature IDs, for example `["usage", "scripts", "commandBar"]`. Multiword feature **keys** are kebab-case; IDs in this list are camelCase:

- `applicationShortcuts`
- `windowSwitcher`
- `stayAwake`
- `commandBar`
- `menuBar`
- `systemMonitor`
- `explain`
- `cleaner`
- `phone`
- `plugins`

`pinned-sidebar-items` lists the features shown at the top of the sidebar, and `sidebar-order` the feature IDs in the order the sidebar shows them; both take the same IDs. An empty `sidebar-order` keeps Frog's own order, and a feature it leaves out follows the one it comes after in that order. Both are what the sidebar writes when you pin a row from its context menu or hold Shift and drag one; **Reset sidebar order** in that menu empties them.

```ini
pinned-sidebar-items = ["usage"]
sidebar-order = ["writing", "scripts", "explain", "dictation"]
```

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

### Hidden bar

The Hidden bar plugin (formerly Menu-bar organization) keeps its settings in `[hidden-bar]` in `config.toml`, written once from the `menubar.*` keys below:

- `auto-hide`: boolean, default `true` (was `menubar.auto-hide`).
- `auto-hide-seconds`: 1–3600 seconds, default 10; fractions are supported (was `menubar.auto-hide-seconds`).
- `start-hidden`: boolean, default `false` (was `menubar.start-collapsed`).
- `always-hidden-section`: boolean, default `false` (was `menubar.permanently-hidden-section`).
- `show-on-hover`: boolean, default `false` (was `menubar.hover-to-reveal`).
- `shortcut`: optional readable shortcut, such as `ctrl+alt+b`; unassigned by default (was `menubar.hotkey`). It is registered with Frog's other global shortcuts.

Actions: `hidden-bar.toggle`, `hidden-bar.show`, `hidden-bar.hide` and `hidden-bar.arrange`. macOS status-item positions stay on each Mac.

### Portable usage display

- `usage.provider`: `Claude` or `OpenAI`.
- `usage.range`: `24h`, `7d`, `30d`.
- `usage.metric`: `API cost`, `Input`, `Output`, `Cache write`, `Cache read`.
- `usage.all-devices`: legacy boolean retained for configuration round trips. OpenAI
  activity now always combines available account totals and local tool activity;
  this setting no longer changes the chart.
- `usage.login-source`: `Automatic`, `Claude Code`, `Claude Desktop`, `OpenCode`, `Pi`. `Claude Desktop` reads the limits the Claude app saves locally and makes no request; `Automatic` shows whichever reading is newer.

These fields select the display and login-source preference only. Accounts, tokens, readings and polling state are not configuration payloads.


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

The look of the Mr. Usage menu bar item:

- `usage.menu-bar-style`: `numbers` (default) shows each limit as a percentage with a thin
  track; `segments` stacks a five-step meter per limit or account, one step per 20%;
  `bars` stacks smooth bars; `columns` stands the bars side by side.
- `usage.menu-bar-palette`: `clean` (default) follows the menu bar's own colour; `level`
  turns each meter green, amber or red as it fills; `spectrum` runs from green to red along
  the meter.

### Menu bar items for System monitor and Stay awake

- `system-monitor.menu-bar`: boolean, default `false`. Shows CPU and GPU load as its own
  menu bar item while System monitor is on; clicking it opens the system overview.
- `system-monitor.menu-bar-style`: a `usage.menu-bar-style` value, default `segments`.
- `system-monitor.menu-bar-palette`: a `usage.menu-bar-palette` value, default `spectrum`.
- `stay-awake.menu-bar` and `stay-awake.menu-bar-style` are now `menu-bar-item` and
  `menu-bar-style` in `[stay-awake]` in `config.toml`, with the session's duration, the screen
  and the lid-closed mode. See [Stay awake](stay-awake.md#settings).

### Explain

Enable with `feature.explain = true`. Turning it on adds the **Explain** answer rule once; a deleted one stays deleted. Answer rules themselves live in JSON (see `action.textOutput` below).

- `explain.context`: boolean, default `true`. Sends the sentence or paragraph around the selection, up to 1,000 characters, with it.
- `explain.notes`: boolean, default `false`. Adds **Save to note** to the answer panel (⌘S) and to answers in History.
- `explain.notes-folder`: the folder notes are written into, as a full path (`/…` or `~/…`). No default: the first Save to note asks for it. A path longer than 256 characters is kept in `config.json` only and is not written to this file.
- `explain.notes-mode`: `per-answer` (default) writes one Markdown file per answer, named after the selection, with YAML front matter (`source`, `app`, `model`, `date`, `tags`). `append` adds a section to the file `explain.notes-file` names.
- `explain.notes-file`: default `Daily/YYYY-MM-DD.md`. The file `append` adds to, relative to the notes folder; `YYYY`, `MM` and `DD` become today's date, missing folders are created, and a path without an extension gets `.md`. Only `.md` and `.markdown` files are accepted.
- `explain.notes-open`: boolean, default `false`. Opens the note after saving: in Obsidian when the folder is inside an Obsidian vault and Obsidian is installed, otherwise in the default Markdown app.

Notes hold the selection, the answer and its follow-ups; the surrounding text sent to the model is never written to them.

The selection bubble offers Explain, the other answer rules and, in text fields, the Writing rules right after text is selected in another app. It needs Explain on and Accessibility allowed.

- `explain.selection-bubble`: boolean, default `false`. Shows the bubble after a selection made with the mouse or the keyboard.
- `explain.bubble-double-click`: boolean, default `true`. Also shows it after a double- or triple-click.
- `explain.bubble-keyboard`: boolean, default `true`. Also shows it when Shift is released after selecting with Shift and the arrow keys.
- `explain.bubble-max-characters`: integer from `100` to `20000`, default `4000`. Longer selections show no bubble.
- `explain.bubble-excluded-apps`: a JSON list of app bundle identifiers the bubble never shows in, such as `["com.apple.Terminal", "com.apple.TextEdit"]`; at most 200, written sorted. Default: 1Password (`com.1password.1password`, `com.agilebits.onepassword7`), Bitwarden (`com.bitwarden.desktop`), Keychain Access (`com.apple.keychainaccess`) and Passwords (`com.apple.Passwords`). `[]` shows it in every app.
- `explain.bubble-expose-text`: `true` (default) shows the bubble in Chrome, Chromium browsers such as Arc and Helium, and Electron apps such as Slack and Obsidian, which hide their text from other apps. It appears where you select with the mouse and offers your answer rules without reading the text; the text is copied when you pick a rule, the way Explain's shortcut copies it, with the clipboard restored. Writing rules do not appear there. Frog never switches these apps to the accessibility mode a screen reader uses, which kept them slower. `false` shows no bubble in them; Explain's shortcut still works there. VS Code and the editors built on it, such as Cursor, Windsurf and VSCodium, never show a bubble without text; they show it only while their screen reader mode is already on. The key keeps its name from an earlier version, which asked these apps to expose their text.

Whether a rule shows in the bubble is chosen with **Show in selection bubble** in its editor, on the Explain page for answer rules and on the Writing page for Writing rules; the switch appears while the bubble is on, and a rule left out is marked "Not in the bubble" in its row. The choice is kept with the rules in `config.json` (`bubbleHiddenRules`), not in this file, a copy made with **Save as copy** keeps it, and a deleted rule leaves it too. On the Explain page, the settings above apart from `explain.selection-bubble` sit under **Options** below the bubble's switch.

### Windows

Enable with `feature.windows = true`. These settings change layouts only while Windows is on:

- `windows.gap`: 0–40 points around the display edge and between windows, default 0.
- `windows.cycle-sizes`: boolean, default `false`; a half shortcut pressed again gives ⅔, then ⅓, then ½ again.
- `windows.portrait-thirds`: boolean, default `true`; thirds run top to bottom on a display taller than wide.
- `windows.respect-stage-manager`: boolean, default `true`; keeps the left 190 points free while Stage Manager is on.
- `windows.layout-picker`: boolean, default `false`; the layout picker opens from its shortcut, the Frog menu and the command bar.
- `windows.drag-to-snap`: boolean, default `false`; a window dragged to a screen edge or corner fills that part of the screen. Paused at the edges while macOS's own edge tiling is on.
- `windows.restore-on-drag`: boolean, default `true`; a window Frog snapped gets its earlier size back when you drag it away. Applies while `windows.drag-to-snap` is on.
- `windows.zone-overlay`: boolean, default `false`; holding Shift while dragging a window shows zones to drop it into. Works while macOS's own edge tiling is on; at an outer screen edge where macOS tiles, Frog leaves the window to macOS.
- `windows.zone-grid`: `halves`, `thirds`, `quarters` or `main-side`, default `thirds`; the zones the overlay shows. Main and side is a left two-thirds and a right third. With `windows.portrait-thirds` on, thirds and main and side run top to bottom on a tall display.

Layout shortcuts stay on their window rules in `config.json` (`rules`). Window commands that are not layouts keep their shortcuts in `config.json` under `preferences.toolkit.windows.shortcuts`, keyed by command name, in the same format as rule shortcuts: the macOS virtual key code and the Carbon modifier bits (Control 4096, Option 2048, Shift 512, Command 256). They have no text keys; record them on the Windows page or edit the JSON:

```json
"windows": { "shortcuts": { "cheatSheet": { "keyCode": 44, "modifiers": 6144 } } }
```

- `cheatSheet`: shows your window shortcuts while held.
- `layoutPicker`: opens the layout picker; works only while `windows.layout-picker` is on.

A command shortcut runs only while Windows is on, and must not repeat another global shortcut then. A command name this version of Frog does not know is ignored.

`preferences.toolkit.windows.setupChoice` is what the old first-run card on the Windows page recorded (`snap` or `manual`). Frog keeps it so the file round-trips; nothing reads it any more.

### App cleaner

Enable with `feature.cleaner = true`. Its setting is `possible-matches` in `[app-cleaner]` in `config.toml`, written once from `cleaner.possible-matches`:

- `possible-matches`: boolean, default `false`. Also lists files whose names only resemble the app; Frog never ticks them.

Removal history, ignored items and dismissed notices stay on each Mac in `~/Library/Application Support/Frog/Cleaner/`. See the [App cleaner guide](cleaner.md).

### Plugins

Enable with `feature.plugins = true`. Installed plugins, what each one may do and what each one stored stay on each Mac in `~/Library/Application Support/Frog/Plugins/`, never in this folder. See the [plugins guide](plugins.md).

### Phone

Enable with `feature.phone = true`. Frog then listens for paired Android phones running Frog Companion on Wi-Fi (TCP port 47321, Bonjour `_frogcompanion._tcp`) and Bluetooth LE; nothing listens, advertises or asks for a permission while it is off. Portable settings:

- `phone.auto-send`: boolean, default `true`. Sends text and images you copy to a connected phone. Items an app marks as concealed, transient or auto-generated, text that looks like a key or password, and files copied in Finder are never sent on their own; files go with **Send clipboard to phone** in the command bar, **Choose…** on the Phone page or `frog run phone.send --file <path>`.

Paired phones and this Mac's companion ID stay on each Mac in `~/Library/Application Support/Frog/phone.json`, and each pairing secret in the login Keychain, never in this folder. See the [protocol](companion-protocol.md).

### Command bar

- `command-bar.learn-choices`: Learn from your choices: rows you pick for what you type are listed a bit higher. Default false. Stored in `~/Library/Application Support/Frog/command-choices.json`, never in this folder.

### Agents

- `agents.access`: boolean, default `false`. Lets the `frog` command, and the AI agents that use it, control Frog through a socket only your user account can open, `~/Library/Application Support/Frog/agent.sock`. See the [agents guide](agents.md).


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

Models are explicit per rule. `explicitRuleModels` records migration from older global defaults; `recentModels` tracks choices for new rules. `explainPresetVersion` records that the Explain rule was created once; deleting the rule does not bring it back. At version 2 the built-in instructions ask for a short, plain answer of at most about 50 words; an answer rule that still has the version 1 text word for word gets the new text once, and edited instructions stay as they are. Legacy global defaults remain readable without rerouting migrated rules. Removing a custom model that a rule still uses requires changing that rule first; an `audio-model`, `cleanup-model` or `text-model` setting that names it returns to its default. Legacy `{{language}}` and `targetLanguage` translation fields remain supported.
