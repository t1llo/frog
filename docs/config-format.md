# config.toml

Frog keeps its settings in one file, `~/.config/frog/config.toml`. Keys before the first `[table]` are Frog's own. `[plugins]` turns plugins on and off, and every other table belongs to the plugin with that ID.

```toml
# Frog settings
appearance = "system"          # system, light or dark
theme = "tokyoNight"
transparency = 0.15
history-limit = 100
hidden-sidebar-items = ["llm-usage"]

[palette.dark]
background = "#1A1B26"

[plugins]
dictation = true
phone = false

[dictation]
mode = "hold"
shortcut = "ctrl+alt+d"
languages = ["en", "de"]

[dictation.recording]
mute-audio = true
```

Save the file and Frog picks up the change within a moment. If the file does not parse, Frog shows the error with its line, for example `line 12: expected a value after '='`, and keeps running on the settings it had.

## The format

The file is TOML 1.0, in the subset below. Frog writes nothing outside this subset.

| Written as | Example |
| --- | --- |
| Comment | `# anything after a hash` |
| Bool | `true`, `false` |
| Integer | `300`, `1_000`, `-3`, `0x1F`, `0o17`, `0b101` |
| Float | `0.15`, `1e3`, `inf`, `nan` |
| String | `"tab\t, quote \", \u00e9"` or literal `'C:\no\escapes'` |
| Multi-line string | `"""` … `"""` or `'''` … `'''`; a line break right after the opening quotes is dropped |
| List | `["en", "de"]`, over several lines if you like, with a trailing comma allowed |
| Inline table | `point = { x = 1, y = 2 }`, on one line, with no trailing comma |
| Table | `[dictation]`, `[dictation.recording]` |
| Key | `mute-audio` (letters, digits, `-`, `_`) or quoted, as in `"my key"` |

These are refused, each with a message saying what to write instead:

- dotted keys (`a.b = 1`): use a `[a]` table;
- lists of tables (`[[items]]`): use a list of inline tables, `items = [{ name = "a" }]`;
- dates and times: write them as strings;
- a key or table that appears twice.

## What Frog does to your edits

Frog edits the file the way you would.

- A file Frog has not changed stays exactly as you wrote it, byte for byte.
- A changed value is replaced where it is. The key's indentation, its spacing and the comment after it stay.
- A value Frog reads but does not change keeps its spelling, so `0x3C` stays `0x3C`.
- A new key goes after the last key of its table. A new table goes at the end of the file, with one blank line before it. A subtable goes after its parent's family.
- Removing a key removes only its line.
- A key Frog does not know is left alone and reported as a warning, which catches typos.
- Frog writes only the keys you changed from their defaults. Everything else stays out of the file until you set it.

If you edit the file while Frog has a change pending, Frog reads your version and applies its change on top. If your version does not parse, Frog does not save until you fix it. Saves are atomic, the file is private (mode 0600), and a missing `~/.config/frog` is created as private (0700). A symlinked config.toml is written at its destination. The limit is 4 MB.

## Shortcuts

A shortcut is a string of modifiers and one key, joined by `+`:

```toml
shortcut = "ctrl+alt+space"
clipboard = "cmd+shift+v"
```

- Modifiers are `ctrl`, `alt`, `shift` and `cmd`, in any order and each at most once. A global shortcut needs `ctrl`, `alt` or `cmd`.
- Keys are `a`–`z`, `0`–`9`, `f1`–`f12`, `space`, `return`, `tab`, `escape`, `delete`, `forward-delete`, the arrows `left`, `right`, `up` and `down`, `home`, `end`, `page-up`, `page-down`, and the punctuation names `minus`, `equal`, `comma`, `period`, `slash`, `backslash`, `semicolon`, `quote`, `grave`, `left-bracket` and `right-bracket`. Any other key can be written as `keycode-N`.
- `cmd+c`, `cmd+x` and `cmd+v` belong to the focused app and are refused.

## For plugin authors

A plugin describes its table as a Swift struct. Defaults come from the property initialisers.

```swift
struct DictationSettings: ConfigSection {
    enum Mode: String, Codable, CaseIterable, Sendable { case toggle, hold }
    struct Recording: ConfigSection { var muteAudio = false }

    var mode = Mode.toggle            // mode = "toggle"; anything else: expected one of toggle, hold
    var shortcut = try! Shortcut("ctrl+alt+d")
    var languages = ["en"]
    var microphoneID: String?         // microphone-id; absent while nil
    var recording = Recording()       // [dictation.recording]
    var rules: [Rule] = []            // a list of inline tables

    static let comments = [
        "": "Dictation: speak, and Frog types it.",   // above [dictation]
        "mode": "toggle: press once to start, again to stop\nhold: record while the shortcut is held",
        "recording.mute-audio": "Mutes other audio",
    ]
}
```

How properties map to the file:

- `muteAudio` is `mute-audio`, and `llmURL` is `llm-url`.
- A nested `ConfigSection` is a subtable, and `[String: V]` is a table whose keys are kept as written.
- A `String` enum is a string, and the error for a wrong one lists the allowed values.
- An optional set to nil is absent.
- Keys missing from the file take the struct's defaults, nested sections and list items included.
- A wrong type is an error with the key's path and line, such as `line 4: [dictation] max-seconds: expected an integer, found a string`.
- `comments` are written above keys and tables that Frog adds; comments already in the file are never touched.

Reading and writing:

```swift
let store = ConfigStore()                     // ~/.config/frog/config.toml; pass fileURL: in tests
try store.load()                              // a missing file reads as empty
let (settings, warnings) = try store.section("dictation", as: DictationSettings.self)
try store.update("dictation", settings)       // writes only what differs from the defaults
try store.setPlugin("dictation", enabled: true)
store.isPluginEnabled("phone", default: false)

store.onChange = { document in /* re-read your section */ }
store.onError = { error in /* show error.description */ }
store.startWatching()                         // Frog's own saves do not call onChange
```

`ConfigDocument.update(_:_:all: true)` writes every key, with its comments, for a starter file. `core(as:)` and `updateCore(_:)` do the same for the top-level keys.

## Moving from the old files

The first time Frog runs on config.toml, it builds the file from the old `config` and `config.json` and leaves both where they are. Keys missing from the old files take the old defaults. Feature names become plugin IDs, and five of them are renamed:

| Old feature | Plugin ID |
| --- | --- |
| `applicationShortcuts` | `shortcuts` |
| `scratchpad` | `notes` |
| `usage` | `llm-usage` |
| `menuBar` | `hidden-bar` |
| `cleaner` | `app-cleaner` |

The others are written in kebab-case: `writing`, `explain`, `dictation`, `command-bar`, `windows`, `window-switcher`, `clipboard`, `scripts`, `system-monitor`, `stay-awake`, `phone` and `plugins`.

The top-level keys it writes are `appearance`, `theme`, `theme-accent`, `accent`, `transparency`, `popup-transparency`, `history-enabled`, `history-hide-text`, `history-limit`, `history-retention-days`, `model-idle-seconds`, `agent-access`, `hidden-sidebar-items`, `pinned-sidebar-items`, `sidebar-order` and `[palette.light]` / `[palette.dark]`. Each plugin adds its own table through `ConfigMigration.register(section:)`.
