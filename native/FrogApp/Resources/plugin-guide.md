# Frog plugins

A community plugin adds a feature of your own to Frog, as complete as the built-in ones: a page in the sidebar, a menu-bar item with a popup, global shortcuts, actions for the command bar and agents, settings, and work that runs in the background. It can read and replace the selection, use folders you pick, run Frog's own actions such as moving windows, and ask your AI model, each only with the permission you approve. You can write one yourself, or describe the feature to an AI agent that has the Frog skill and let it build, install and check it. Plugins run only on your Mac. You can share one as a file, or list it in the signed directory that Frog installs from.

This file is the contract between Frog and plugins. `frog plugin guide` prints the same reference from the running app.

## What a plugin is

A plugin is a folder with a `plugin.json` manifest and web files: HTML, CSS, JavaScript and images. Frog shows the plugin's page in a sandboxed web view inside its window. The page talks to Frog through `window.frog`, and every call is checked against the permissions you approved.

```
word-counter/
├── plugin.json
├── index.html
├── app.js
├── popup.html         only with a menu-bar item that has a popup
└── scripts/           only with the "scripts" permission
    └── stats.sh
```

A plugin with a menu-bar popup has two pages: its page in Frog's window and the popup. Each runs its own scripts, and both share the plugin's storage and settings.

## The manifest

```json
{
  "id": "com.example.word-counter",
  "name": "Word counter",
  "version": "1.0.0",
  "description": "Counts the words on the clipboard.",
  "author": "Jane Appleseed",
  "homepage": "https://github.com/jane/frog-word-counter",
  "symbol": "textformat.123",
  "entry": "index.html",
  "frog": "1.0.40",
  "permissions": ["clipboard-read", "notifications", "menubar", "hotkeys"],
  "hosts": [],
  "scripts": {},
  "menubar": { "symbol": "textformat.123", "popup": "popup.html", "width": 300, "height": 220 },
  "settings": [
    { "key": "unit", "title": "Count", "type": "choice", "choices": ["words", "characters"], "default": "words" }
  ],
  "actions": [
    {
      "id": "count", "title": "Count words on the clipboard", "effect": "read", "keywords": "words length",
      "shortcut": "ctrl+alt+shift+w",
      "parameters": [{ "name": "unit", "type": "choice", "choices": ["words", "characters"] }]
    }
  ]
}
```

| Key | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Lowercase letters, digits, dots and hyphens, 3 to 64 characters, such as `com.example.word-counter`. It never changes between versions. |
| `name` | yes | Up to 40 characters, shown in the sidebar. |
| `version` | yes | `major.minor.patch`, such as `1.2.0`. |
| `description` | yes | One sentence, up to 200 characters. |
| `author` | no | Who made it. |
| `homepage` | no | An `https` link to the source or a page about it. |
| `symbol` | no | An SF Symbol name for the sidebar. Defaults to `puzzlepiece.extension`. |
| `entry` | no | The page Frog opens. Defaults to `index.html`. Use `null` for a plugin with commands only. |
| `frog` | no | The oldest Frog version the plugin works with. |
| `permissions` | no | What the plugin may do; see below. |
| `hosts` | with `network` | The hosts `frog.fetch` may reach, such as `api.github.com` or `*.example.com`. |
| `scripts` | with `scripts` | Names mapped to shell scripts inside the folder, such as `{"stats": "scripts/stats.sh"}`. |
| `actions` | no | What the command bar, shortcuts and agents can run; see [Actions](#actions). They need a page. |
| `menubar` | with `menubar` | The plugin's menu-bar item; see [Menu bar](#menu-bar). |
| `settings` | no | Up to 20 settings the user changes in the plugin's settings sheet; see [Settings](#settings). |
| `uses` | with `frog-actions` | Frog's own actions the plugin may run, such as `windows.move`, or all of a feature's, such as `windows.*`; see [Frog's own actions](#frogs-own-actions). |
| `commands` | no | Older command bar rows. `id` is what the page receives; `title` is shown; `keywords` help search; `"show": false` runs the command without opening the page. New plugins use actions. |

Limits: at most 400 files and 20 MB in all, and no symbolic links. Hidden files and folders, such as `.git` and `.DS_Store`, are left out when a plugin is installed or packed.

## Actions

An action is one thing the plugin does, with typed parameters. Each one appears in the command bar, can get a keyboard shortcut in Frog → Shortcuts, and runs from agents as `frog run community.<plugin id>.<action id>`; `frog actions community` lists them with their parameters. The page answers with `frog.action`, and Frog loads the page in the background first when it is not running.

| Key | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Lowercase letters, digits and hyphens, unique among the plugin's actions and commands. |
| `title` | yes | Up to 60 characters, shown in the command bar. |
| `effect` | yes | `read`, `write` or `network`: the most the action may do. The review shows it. |
| `parameters` | no | Up to 8, each with a `name`, a `type` (`text`, `integer`, `boolean` or `choice`), `required`, `help` and, for a choice, its `choices`. `stdin`, `json` and `help` are reserved names. |
| `input` | no | `true` when the action reads text given on standard input, such as `frog run … --stdin < notes.txt`. |
| `keywords` | no | Words that help the command bar find it. |
| `shortcut` | with `hotkeys` | A global shortcut that runs it, such as `ctrl+alt+shift+w`, with ⌘, ⌥ or ⌃; see [Shortcuts](#shortcuts). Only for an action without required parameters. |

The effect is enforced while the action runs:

- `read` may read storage, settings, the clipboard, the selection and files, and list folders.
- `write` may also change storage and settings, write the clipboard, replace the selection, write files, notify, open links, run scripts, run Frog's own actions, change the menu-bar item and show the page.
- `network` may also use `frog.fetch` and `frog.ai`, and needs the `network` or `ai` permission.

A call beyond the action's effect rejects, even when the plugin has the permission for it. Permissions still apply on top: a `write` action can write the clipboard only with `clipboard-write`. The limit holds for 30 seconds after the handler answers or times out, so a timer it set stays inside it, and a page Frog loaded only for a `read` action closes then. A `read` action may read the clipboard while it runs, but does not open the window after a command in which a hidden page may write the clipboard or show itself.

```js
frog.action("count", async ({ unit }, input) => {
  const text = input ?? await frog.clipboard.readText() ?? "";
  const count = unit === "characters" ? text.length : text.split(/\s+/).filter(Boolean).length;
  return { text: `${count} ${unit ?? "words"}`, count };   // or just a string
});
```

The handler receives the parameters, typed, and the text from standard input or `null`. What it returns is the answer: a string, or an object whose `text` is shown and which agents receive as JSON with `--json`. A thrown error fails the action with its message. One action runs at a time per plugin, for at most 60 seconds. Register handlers at startup: an action that arrives first waits up to 5 seconds for its handler.

An action without required parameters is a command bar row of its own. One with required parameters runs from shortcuts and agents, which give its values.

## A whole feature

A page and actions are where a plugin starts. These parts make it a feature like Frog's own; each needs its permission, and the review shows what each one does.

### Menu bar

With the `menubar` permission and a `menubar` entry, the plugin gets its own menu-bar item while it is on.

| Key | Meaning |
| --- | --- |
| `symbol` | An SF Symbol for the item. Defaults to the plugin's `symbol`. |
| `title` | Up to 24 characters beside the symbol, such as a count. The page changes it with `frog.menubar.set`. |
| `popup` | An HTML file in the folder that opens beneath the item, in Frog's popup style: the plugin's name above, its popup page below. |
| `width`, `height` | The popup page's size in points: 200 to 480 wide, 80 to 640 high; 320 by 360 by default. `frog.menubar.resize(height)` changes the height while it is open. |
| `action` | Instead of a popup: the action a click runs, which has no required parameters. |

An item with neither opens the plugin's page. The popup loads when first opened and keeps running while the plugin is on, so it opens at once; it hears `show` and `hide`, and `frog.info.surface` is `"popup"` in it. A click elsewhere or Escape closes it, as `frog.menubar.close()` does.

### Shortcuts

With the `hotkeys` permission, an action's `shortcut` works in every app while the plugin is on. It runs the action as a command, so the action may then show the page, write the clipboard or read the selection. The user changes or clears each key in the plugin's settings sheet; a key Frog already uses is not registered, and the sheet says so. Shortcuts the user binds in Frog → Shortcuts to `community.<id>.<action>` need no permission.

### Background

With the `background` permission the plugin's page loads when Frog starts and stays loaded while its page is closed, so its timers keep running and `frog.close()` does not stop it. It hears what happens on the Mac with `frog.on`:

| Event | When |
| --- | --- |
| `wake`, `sleep` | The Mac woke up or is going to sleep. |
| `lock`, `unlock` | The screen locked or unlocked. |
| `app` | Another app came to the front; the value is `{ name, bundleId }`. |
| `clipboard` | The clipboard changed, with `clipboard-read` too. `frog.clipboard.readText()` works for 10 seconds after. Text a password manager marks as concealed is not announced. |

### Settings

`settings` lists what the user can change in the plugin's settings sheet, which opens from the plugin's page and its row in Community plugins, in Frog's own controls. No permission is needed.

| Key | Meaning |
| --- | --- |
| `key` | Lowercase letters, digits and hyphens. |
| `title` | Up to 40 characters. |
| `type` | `text`, `integer`, `boolean`, `choice` or `secret`. |
| `help` | One line under the title, up to 120 characters. |
| `default` | The value before the user changes it. Not for a secret. |
| `choices` | For `choice`: 1 to 20 options. |
| `min`, `max` | For `integer`. |

A `secret`, such as an API token, is kept in the macOS Keychain, never in the plugin's files or storage, and is deleted with the plugin. The page reads values with `frog.settings.get` and hears changes with `frog.on("settings", ({ key, value }) => …)`; a secret's change carries no value.

### Folders

With the `files` permission the page asks the user for a folder with `frog.files.pick()`, while its page or popup is open. It then reads, writes, lists and moves to the Trash the files in that folder, and only there: paths are relative, with no `..` or hidden names, and links that lead outside are refused. The settings sheet lists the folders a plugin has and removes them. Files can be 10 MB.

### The selection

With the `selection` permission, `frog.selection.read()` reads the text selected in the app in front through Frog's Accessibility access, while one of the plugin's actions runs or within 10 seconds of a command or shortcut. `frog.selection.replace(text)` replaces that selection, within two minutes of reading it.

### Frog's own actions

With the `frog-actions` permission and `uses`, `frog.runAction(id, params)` runs Frog's actions as an agent would, such as `windows.move` or `notes.add`, and answers `{ text, json }`. `frog actions` lists them with their parameters, and a feature that is off has none. The actions of Scripts, Shortcuts, History, App cleaner, Phone and other plugins are never available to plugins. The review lists each entry in `uses`, and an update that adds one waits for review.

## Plug and play

Every feature, built in or a plugin, turns on and off in Frog → Plugins without restarting Frog. Turning a community plugin off, or Community plugins as a whole, unloads its pages and removes its menu-bar item, shortcuts, background work and notification handling. Removing a plugin also moves its files and storage to the Trash, deletes its secrets from the Keychain and its waiting notifications, and forgets its folders. Nothing of it stays registered.

## Permissions

A plugin without permissions can show its page, keep its own storage and receive its commands. Everything else needs a permission that you approve when you install it.

| Permission | What it allows |
| --- | --- |
| `clipboard-read` | Read the text on the clipboard. Text that password managers mark as concealed is never given. |
| `clipboard-write` | Put text on the clipboard. |
| `selection` | Read the text selected in the app in front, and replace it, right after one of its actions or shortcuts. |
| `notifications` | Show a notification, with up to 3 buttons that answer the plugin. |
| `links` | Open web links in your browser. |
| `menubar` | Show its own menu-bar item, with a popup. |
| `hotkeys` | Give its actions global keyboard shortcuts. |
| `background` | Start with Frog and keep running with its page closed, hearing when the Mac wakes, sleeps or locks, the app in front changes and, with `clipboard-read`, the clipboard changes. |
| `files` | Read, write and trash files in folders you pick for it, and only those. |
| `network` | Send requests with `frog.fetch` to the hosts in `hosts`, and only those. |
| `ai` | Send text to the AI model your Writing rules use by default. Your keys stay in Frog; a cloud model's provider bills you for it. |
| `frog-actions` | Run the Frog actions listed in `uses`, with the permissions you gave Frog, such as Accessibility. |
| `scripts` | Run the shell scripts listed in `scripts`, with your user's full access to this Mac and the permissions you gave Frog, such as Accessibility. Install a plugin with scripts only when you trust its author and have read the scripts. |

The review marks the broad ones with a caution: `clipboard-read`, `selection`, `background`, `files`, `network`, `ai`, `frog-actions` and `scripts`.

What the sandbox enforces:

- The page loads only from its own folder, at `frog-plugin://<id>/`. Every other address is blocked, including links, frames, forms, `fetch`, WebSockets and WebRTC; network requests go through `frog.fetch`, which Frog checks against `hosts`.
- WebRTC, WebTransport, DNS prefetching, the browser's clipboard API (`navigator.clipboard`), web notifications, geolocation and sharing are off in every frame. Use `frog.fetch`, `frog.clipboard` and `frog.notify` instead. Text the user selects and copies in the page copies as usual.
- The page has no cookies or shared website data, and cannot leave its folder or navigate elsewhere.
- `alert`, `confirm` and `prompt` show as a sheet on the plugin's page, naming the plugin, and only while the page is shown; a hidden page gets the answer of a dismissed dialog. The user can turn a page's dialogs off.
- Plugins cannot read Frog's settings, notes, history, keys or other plugins' storage.
- Frog records the permissions, hosts, Frog actions and script contents you approved. An update that asks for more, adds a host or an entry in `uses`, or changes a script waits for you to review it again; any other update applies directly. A plugin with scripts also pins all its files, since a script can run any of them: any change to it waits for review.
- A plugin from somewhere else than the installed one with the same id, such as a file or another author's link, is reviewed as a new install, and the review says that it replaces the installed plugin and gets what that one stored.
- Only you can approve or turn on a plugin, in Frog's window, apart from a directory plugin that asks for no permissions. The `frog` command can install one for review, but not approve it.

## The `frog` object

Every function except `frog.on` returns a promise. A call that is not allowed, such as one without the permission it needs, rejects with an `Error` whose message says why.

```js
await frog.storage.get("key")            // the stored value, or null
await frog.storage.set("key", value)     // any JSON value; 5 MB per plugin in all
await frog.storage.remove("key")
await frog.storage.keys()

await frog.clipboard.readText()          // clipboard-read: the text, or null
await frog.clipboard.writeText("text")   // clipboard-write

await frog.notify("Title", "Body")       // notifications
await frog.notify("Break is over", "", { at: Date.now() + 5 * 60_000, id: "break",
  actions: [{ id: "snooze", title: "Snooze 5 minutes" }] })
await frog.cancelNotification("break")
frog.on("notification", ({ id, action }) => { … })   // a click ("open") or a button's id
await frog.openURL("https://…")          // links

await frog.settings.get("unit")          // the value, or its default; a secret from the Keychain
await frog.settings.all()                // every setting but secrets
await frog.settings.set("unit", "words") // checked against plugin.json; null restores the default
frog.on("settings", ({ key, value }) => { … })

await frog.selection.read()              // selection: { text, app }
await frog.selection.replace("text")     // selection: replaces what read() read

await frog.runAction("windows.move", { app: "Safari", position: "left" })
                                         // frog-actions: { text, json }

const folder = await frog.files.pick()   // files: { id, name }, or null when cancelled
await frog.files.folders()               // [{ id, name }]
await frog.files.list(folder.id, "notes")             // [{ name, directory, size, modified }]
await frog.files.read(folder.id, "notes/today.md")    // text; { as: "base64" } for bytes
await frog.files.write(folder.id, "notes/today.md", "# Today")
await frog.files.trash(folder.id, "notes/old.md")

await frog.menubar.set({ title: "3", symbol: "timer", tooltip: "3 left" })   // menubar
await frog.menubar.resize(300)           // the popup's height
await frog.menubar.close()               // close the popup

const response = await frog.fetch("https://api.github.com/…", {
  method: "GET", headers: {}, body: "", as: "text"   // as: "text", "json" or "base64"
})                                       // network: { status, ok, url, headers, body }

await frog.ai("Summarize in one sentence:", text)    // ai: the model's answer as text

const result = await frog.run("stats", { args: ["--short"], input: "text" })
                                         // scripts: { output, status, truncated }
await frog.run("report", { as: "json", timeout: 120, onOutput: (sofar) => { … } })
                                         // json: the output parsed; onOutput: the output as it grows

const off = frog.action("count", async (params, input) => "answer")   // answer an action; off() unregisters
const stop = frog.on("command", (id) => { … })   // an older command was chosen; stop() unsubscribes
frog.on("show", () => { … })             // the page or popup came into view, the first time included
frog.on("hide", () => { … })             // another page took its place, or the popup closed
frog.on("storage", ({ key }) => { … })   // the plugin's other page, page or popup, stored something
frog.on("wake", () => { … })             // background: also sleep, lock, unlock, app, clipboard
await frog.show()                        // bring the plugin's page forward, right after a command
await frog.close()                       // unload the page while hidden; close the popup
frog.info                                // { id, name, version, permissions, frog, surface }
```

Details:

- **Commands.** A command that arrives before the page listens waits for its first `frog.on("command")` listener, so register it at startup. A command with `"show": false` runs the page without opening it; call `frog.close()` when the work is done.
- **Showing the page.** `frog.show` works within 10 seconds of one of the plugin's commands, so a page in the background cannot bring Frog forward by itself.
- **Clipboard.** `readText` and `writeText` work while the page is shown, or within 10 seconds of one of the plugin's commands. `readText` returns `null` when the clipboard holds no text, or text a password manager marked as concealed.
- **Notifications.** `at` is a time in milliseconds, such as `Date.now() + 60_000`, at most 30 days ahead; without it the notification shows at once, at most 10 a minute. A plugin has at most 20 waiting. A notification with the same `id` replaces the earlier one. Clicking one opens the plugin's page. A notification has up to 3 `actions`, each with an `id` of lowercase letters, digits and hyphens and a `title` of up to 40 characters; a click on one loads the page if needed and sends `notification` with the notification's `id` and the button's, and counts as a command.
- **Links.** `openURL` and links the user clicks open in the default browser, http and https only, with the `links` permission.
- **Fetch.** `frog.fetch` resolves for any HTTP status; check `ok` or `status`. It rejects when the host is not allowed, the request is not valid or the network fails. With `as: "json"` it parses `body` and rejects when the answer is not JSON. Requests carry no cookies or credentials, redirects to other hosts are not followed, request bodies can be 1 MB and answers 5 MB, and Frog sets `Host`, `Cookie`, `Origin`, `Referer` and similar headers itself.
- **AI.** One call runs at a time per plugin, with the model your Writing rules use by default.
- **Scripts.** Scripts run with `/bin/zsh` in the plugin's own data folder. They receive `args` as `$1`, `$2` and so on, `input` in the `FROG_INPUT` environment variable and the plugin's id in `FROG_PLUGIN_ID`. They stop after `timeout` seconds, 60 by default and at most 300, and their output is cut at 1 MB. `onOutput` receives everything printed so far as the script runs. A script runs only while it and every other file of the plugin are byte for byte the ones you approved.
- **Settings.** `set` checks the value against the setting's type, choices and range, and rejects a key plugin.json does not declare.
- **AI without keys.** `frog.ai` uses the user's own providers through Frog: the plugin never sees an API key.

`console.log`, errors and rejected promises go to the plugin's log, which `frog plugin logs <id>` prints.

## Looking like Frog

Frog sets its design tokens as CSS variables on the page, for the light and dark appearance and the theme you chose, the same values its own views use:

- Colours: `--frog-ink`, `--frog-muted`, `--frog-canvas`, `--frog-surface`, `--frog-sidebar`, `--frog-inset`, `--frog-border`, `--frog-accent`, `--frog-on-accent` (text on the accent), `--frog-good`, `--frog-warning`, `--frog-critical`.
- Layers over the page: `--frog-card`, `--frog-control` (a control's fill), `--frog-hover`, `--frog-pressed`, `--frog-selection` (a chosen row), `--frog-switch-track`, `--frog-line` (the line between a section's rows) and `--frog-hairline`.
- `--frog-font`, Frog's radii, which nest: `--frog-radius-small` (4px, badges and key caps), `--frog-radius` (10px, rows and fields), `--frog-radius-card` (14px) and `--frog-radius-panel` (18px); and heights: `--frog-control-height` (28px), `--frog-compact-height` (24px) and `--frog-row-height` (38px).

Link `/_frog/frog.css` for Frog's controls, cards and type:

```html
<link rel="stylesheet" href="/_frog/frog.css">
```

Like Frog, it separates content with space rather than lines. Buttons, segmented controls and switches are capsules; the main action is filled with the accent; cards are thin layers with no border. In the popup the page has no background of its own: Frog's panel shows through, and `:root` has `data-frog-surface="popup"`, which makes controls compact.

It styles plain elements (headings, `button`, `input`, `textarea`, `select`, `table`, `code`) and adds these classes:

| Class | Use |
| --- | --- |
| `frog-page` | The page's main element: padding and a column of sections. |
| `frog-header`, `frog-subtitle` | A header with the `h1` and a line under it on the left, buttons on the right. |
| `frog-card` | A card around a section. |
| `frog-stack`, `frog-row`, `frog-spacer` | A column, a row, and a gap that pushes what follows to the end of a row. |
| `frog-grid` | Equal columns that wrap; set `--min` for the narrowest column, such as `style="--min: 160px"`. |
| `frog-list`, `frog-item` | A list of rows that highlight on hover; `frog-item` on a `button` or `a` in a row makes the whole row clickable. |
| `frog-stat` | A number in `strong` over a label in `span`. |
| `frog-badge`, `frog-accent` | A small label; with `frog-accent`, in the accent color. |
| `frog-segmented` | Buttons side by side, one chosen; mark it with `aria-pressed="true"`. |
| `frog-primary`, `frog-quiet`, `frog-destructive`, `frog-compact` | The main button in the accent, a button with no fill until hovered, one that deletes, and a 24-point button. |
| `frog-section`, `frog-rows`, `frog-setting` | A settings group as in Frog: a caption, then a card of rows with a title (and `small` under it) on the left and a control on the right. |
| `frog-switch` | Frog's switch, on `<input type="checkbox">`. |
| `frog-meter` | A bar filled to `style="--value: 0.4"`; with `frog-warning` or `frog-critical` in that colour. |
| `kbd` | A key cap, for showing a shortcut: `<kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd>`. |
| `frog-muted`, `frog-caption`, `frog-small`, `frog-tabular` | Quieter text, a caption, smaller text and figures of equal width. |
| `frog-notice`, `frog-error`, `frog-empty`, `frog-spinner` | A note, an error, an empty state and a loading spinner. |

## Building one with an AI agent

With agent access on (Settings → Agents) and the Frog skill installed, ask your agent for the feature you want, such as "build me a Frog plugin that shows my open GitHub pull requests". It uses these commands:

```
frog plugin guide                         this reference, from the running Frog
frog plugin new <folder> [--name N] [--id ID] [--with menubar,hotkey,background,settings]
                                          start a plugin, or a whole feature, from a template
frog plugin validate <folder>             check the manifest and files
frog plugin install <folder>              install or update it for your review
frog plugin install <file | https link | id>     open the review of a shared plugin
frog plugin list [--directory]            installed plugins, or the signed directory's
frog plugin snapshot <id> [--popup] [--output f.png]
                                          a picture of the page or popup, to check its layout
frog plugin logs <id>                     the page's console and errors
frog plugin open <id>                     show its page in Frog's window
frog plugin publish <folder|id> [--output f]     a .frogplugin file and its directory entry
frog plugin remove <id>                   remove it, to the Trash
frog run community.<id>.<action>          run one of its actions, as the command bar does
```

Your first install of a plugin waits for you in Frog → Community plugins, which shows its review. After you approve it, the agent's updates apply at once while they ask for nothing new. A plugin with scripts waits for you after every change.

### For agents

A sentence such as "add a menu-bar timer that pauses my music when it ends" is enough: build the whole feature, then check it the way a user would.

1. Community plugins must be on: `frog features list` shows it. Ask the user before `frog features enable plugins`.
2. Plan the feature from the user's sentence: what the page shows, which actions it has, and which parts of [A whole feature](#a-whole-feature) it needs, such as a menu-bar item, a shortcut, background work or settings. `frog actions` lists Frog's own actions a plugin can run with `uses`.
3. Start with `frog plugin new <folder> --with <parts>` in a folder of the user's choice, outside Frog's own folders, such as `--with menubar,hotkey,settings`. It writes a working plugin with each part, which you then change. Give a plugin the user may share an id they own, such as `io.github.<user>.<name>`.
4. Ask for the fewest permissions that do the job, and only the hosts the plugin needs. Give each action the smallest effect that does its job. Keep everything in the folder: pages cannot load scripts, styles or fonts from the web.
5. Use Frog's stylesheet, its tokens and `frog-*` classes, and keep pages simple and calm like Frog's own: a header, then sections and cards; in a popup, one short column.
6. Run `frog plugin validate <folder>` and fix every hint, then `frog plugin install <folder>`. The first install waits for the user: tell them to approve it in Frog's window, and wait until `frog plugin list` shows it `on`. A plugin with scripts waits for the user after every change, so prefer a page without scripts when one can do the job.
7. Check your work: `frog plugin snapshot <id>` and, with a popup, `frog plugin snapshot <id> --popup`, and look at the pictures; `frog plugin logs <id>` for errors; `frog run community.<id>.<action>` for each action. After each change, install again; the pages reload.
8. Never put API keys or tokens in the plugin's files or storage. Declare a `secret` setting: the user enters it in the plugin's settings sheet, and Frog keeps it in the Keychain. For AI, use `frog.ai`, which needs no key at all.
9. Tell the user what you built and how to use it: the menu-bar item, the shortcut, where its settings are.
10. To share it, run `frog plugin publish <folder>` and give the user the file, its SHA-256 and the directory entry it prints.

## Sharing

`frog plugin publish` makes a `.frogplugin` file, a zip of the folder, and prints its SHA-256 and the entry for the plugin directory.

### The directory

Frog → Community plugins → Directory lists the plugins in the directory at <https://frog.beffa.xyz/plugins/>, with search and one-click install. Frog reads `https://frog.beffa.xyz/plugins/registry.json`, which lists for each plugin its id, name, summary, version, author, permissions, the links to its manifest and file, the file's SHA-256 and an Ed25519 signature over all of these. Frog has the directory's public key built in, leaves out every entry whose signature does not check, and installs a file only when its SHA-256 is the signed one and its manifest has the listed id and version. A plugin that asks for no permissions installs at once, and so does a newer version that asks for nothing new: no permission, host or script beyond what you approved, and no action with a larger effect than before. Anything else opens its review first, like every other install. The Directory never installs a version older than the one you have.

To have yours listed, open an issue at <https://github.com/t1llo/frog/issues/new> with the entry `frog plugin publish` printed and the `.frogplugin` file attached. Listed plugins are read before they are signed, but they remain their authors' work: review the permissions before you install one.

### On your own

Publish the file where people can download it over `https`, such as a GitHub release. Anyone can install it from Frog → Community plugins → Build your own → Install from a link, or with a link of this form, which opens Frog's review:

```
frog://plugins/install?url=<https URL of the .frogplugin>&sha256=<hex>
```

Frog downloads the file over https only, and refuses it when its SHA-256 does not match the link. The review says when a file is not in the signed directory.
