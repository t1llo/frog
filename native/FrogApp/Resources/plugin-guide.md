# Frog plugins

A plugin adds a feature of your own to Frog: a page in the sidebar, commands in the command bar, or both. You can write one yourself, or ask an AI agent that has the Frog skill to build it for you. Plugins run only on your Mac; sharing one is up to you.

This file is the contract between Frog and plugins. `frog plugins guide` prints the same reference from the running app.

## What a plugin is

A plugin is a folder with a `plugin.json` manifest and web files: HTML, CSS, JavaScript and images. Frog shows the plugin's page in a sandboxed web view inside its window. The page talks to Frog through `window.frog`, and every call is checked against the permissions you approved.

```
word-counter/
├── plugin.json
├── index.html
├── app.js
└── scripts/           only with the "scripts" permission
    └── stats.sh
```

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
  "permissions": ["clipboard-read", "notifications"],
  "hosts": [],
  "scripts": {},
  "commands": [
    { "id": "count", "title": "Count words on the clipboard", "keywords": "words length" }
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
| `commands` | no | Command bar rows. `id` is what the page receives; `title` is shown; `keywords` help search; `"show": false` runs the command without opening the page. |

Limits: at most 400 files and 20 MB in all, and no symbolic links. Hidden files and folders, such as `.git` and `.DS_Store`, are left out when a plugin is installed or packed.

## Permissions

A plugin without permissions can show its page, keep its own storage and receive its commands. Everything else needs a permission that you approve when you install it.

| Permission | What it allows |
| --- | --- |
| `clipboard-read` | Read the text on the clipboard. Text that password managers mark as concealed is never given. |
| `clipboard-write` | Put text on the clipboard. |
| `notifications` | Show a notification. |
| `links` | Open web links in your browser. |
| `network` | Send requests with `frog.fetch` to the hosts in `hosts`, and only those. |
| `ai` | Send text to the AI model your Writing rules use by default. A cloud model's provider bills you for it. |
| `scripts` | Run the shell scripts listed in `scripts`, with your user's full access to this Mac and the permissions you gave Frog, such as Accessibility. Install a plugin with scripts only when you trust its author and have read the scripts. |

What the sandbox enforces:

- The page loads only from its own folder, at `frog-plugin://<id>/`. Every other address is blocked, including links, frames, forms, `fetch`, WebSockets and WebRTC; network requests go through `frog.fetch`, which Frog checks against `hosts`.
- WebRTC, WebTransport, DNS prefetching, the browser's clipboard API (`navigator.clipboard`), web notifications, geolocation and sharing are off in every frame. Use `frog.fetch`, `frog.clipboard` and `frog.notify` instead. Text the user selects and copies in the page copies as usual.
- The page has no cookies or shared website data, and cannot leave its folder or navigate elsewhere.
- `alert`, `confirm` and `prompt` show as a sheet on the plugin's page, naming the plugin, and only while the page is shown; a hidden page gets the answer of a dismissed dialog. The user can turn a page's dialogs off.
- Plugins cannot read Frog's settings, notes, history, keys or other plugins' storage.
- Frog records the permissions, hosts and script contents you approved. An update that asks for more, adds a host or changes a script waits for you to review it again; any other update applies directly. A plugin with scripts also pins all its files, since a script can run any of them: any change to it waits for review.
- A plugin from somewhere else than the installed one with the same id, such as a file or another author's link, is reviewed as a new install, and the review says that it replaces the installed plugin and gets what that one stored.
- Only you can approve or turn on a plugin, in Frog's window. The `frog` command can install one for review, but not approve it.

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
await frog.notify("Break is over", "", { at: Date.now() + 5 * 60_000, id: "break" })
await frog.cancelNotification("break")
await frog.openURL("https://…")          // links

const response = await frog.fetch("https://api.github.com/…", {
  method: "GET", headers: {}, body: "", as: "text"   // as: "text", "json" or "base64"
})                                       // network: { status, ok, url, headers, body }

await frog.ai("Summarize in one sentence:", text)    // ai: the model's answer as text

const result = await frog.run("stats", { args: ["--short"], input: "text" })
                                         // scripts: { output, status, truncated }

const stop = frog.on("command", (id) => { … })   // a command bar row was chosen; stop() unsubscribes
frog.on("show", () => { … })             // the page came into view, the first time included
frog.on("hide", () => { … })             // another page took its place
await frog.show()                        // bring the plugin's page forward, right after a command
await frog.close()                       // unload the plugin while its page is hidden
frog.info                                // { id, name, version, permissions, frog }
```

Details:

- **Commands.** A command that arrives before the page listens waits for its first `frog.on("command")` listener, so register it at startup. A command with `"show": false` runs the page without opening it; call `frog.close()` when the work is done.
- **Showing the page.** `frog.show` works within 10 seconds of one of the plugin's commands, so a page in the background cannot bring Frog forward by itself.
- **Clipboard.** `readText` and `writeText` work while the page is shown, or within 10 seconds of one of the plugin's commands. `readText` returns `null` when the clipboard holds no text, or text a password manager marked as concealed.
- **Notifications.** `at` is a time in milliseconds, such as `Date.now() + 60_000`, at most 30 days ahead; without it the notification shows at once, at most 10 a minute. A plugin has at most 20 waiting. A notification with the same `id` replaces the earlier one. Clicking one opens the plugin's page.
- **Links.** `openURL` and links the user clicks open in the default browser, http and https only, with the `links` permission.
- **Fetch.** `frog.fetch` resolves for any HTTP status; check `ok` or `status`. It rejects when the host is not allowed, the request is not valid or the network fails. With `as: "json"` it parses `body` and rejects when the answer is not JSON. Requests carry no cookies or credentials, redirects to other hosts are not followed, request bodies can be 1 MB and answers 5 MB, and Frog sets `Host`, `Cookie`, `Origin`, `Referer` and similar headers itself.
- **AI.** One call runs at a time per plugin, with the model your Writing rules use by default.
- **Scripts.** Scripts run with `/bin/zsh` in the plugin's own data folder. They receive `args` as `$1`, `$2` and so on, `input` in the `FROG_INPUT` environment variable and the plugin's id in `FROG_PLUGIN_ID`. They stop after 60 seconds, and their output is cut at 1 MB. A script runs only while it and every other file of the plugin are byte for byte the ones you approved.

`console.log`, errors and rejected promises go to the plugin's log, which `frog plugins logs <id>` prints.

## Looking like Frog

Frog sets these CSS variables on the page, for the light and dark appearance and the theme you chose: `--frog-ink`, `--frog-muted`, `--frog-canvas`, `--frog-surface`, `--frog-inset`, `--frog-border`, `--frog-accent`, `--frog-good`, `--frog-warning`, `--frog-critical` and `--frog-font`. Link `/_frog/frog.css` for Frog's buttons, inputs, cards and type:

```html
<link rel="stylesheet" href="/_frog/frog.css">
```

It styles plain elements (headings, `button`, `input`, `textarea`, `select`, `table`, `code`) and adds these classes:

| Class | Use |
| --- | --- |
| `frog-page` | The page's main element: padding and a column of sections. |
| `frog-header`, `frog-subtitle` | A header with the `h1` and a line under it on the left, buttons on the right. |
| `frog-card` | A bordered section. |
| `frog-stack`, `frog-row`, `frog-spacer` | A column, a row, and a gap that pushes what follows to the end of a row. |
| `frog-grid` | Equal columns that wrap; set `--min` for the narrowest column, such as `style="--min: 160px"`. |
| `frog-list`, `frog-item` | A list of rows; `frog-item` on a `button` or `a` in a row makes the whole row clickable. |
| `frog-stat` | A number in `strong` over a label in `span`. |
| `frog-badge`, `frog-accent` | A small label; with `frog-accent`, in the accent color. |
| `frog-segmented` | Buttons side by side, one chosen; mark it with `aria-pressed="true"`. |
| `frog-primary`, `frog-quiet` | The main button, and a button without a border. |
| `frog-muted`, `frog-caption`, `frog-small`, `frog-tabular` | Quieter text, a caption, smaller text and figures of equal width. |
| `frog-notice`, `frog-error`, `frog-empty`, `frog-spinner` | A note, an error, an empty state and a loading spinner. |

## Building one with an AI agent

With agent access on (Settings → Agents) and the Frog skill installed, ask your agent for the feature you want, such as "build me a Frog plugin that shows my open GitHub pull requests". It uses these commands:

```
frog plugins guide                        this reference, from the running Frog
frog plugins new <folder> [--name N] [--id ID]   start a plugin from a template
frog plugins check <folder>               check the manifest and files
frog plugins install <folder>             install or update it for your review
frog plugins list                         installed plugins and their state
frog plugins snapshot <id> [--output f.png]      a picture of the page, to check its layout
frog plugins logs <id>                    the page's console and errors
frog plugins run <id> <command>           run one of its commands, as the command bar does
frog plugins open <id>                    show its page in Frog's window
frog plugins pack <folder|id> [--output f]       a .frogplugin file to share, with its SHA-256
frog plugins remove <id>                  remove it, to the Trash
```

Your first install of a plugin waits for you in Frog → Plugins, which shows its review. After you approve it, the agent's updates apply at once while they ask for nothing new. A plugin with scripts waits for you after every change.

### For agents

1. Plugins must be on: `frog features list` shows it. Ask the user before `frog features enable plugins`.
2. Start with `frog plugins new <folder>` in a folder of the user's choice, outside Frog's own folders. Give a plugin the user may share an id they own, such as `io.github.<user>.<name>`.
3. Ask for the fewest permissions that do the job, and only the hosts the plugin needs. Keep everything in the folder: pages cannot load scripts, styles or fonts from the web.
4. Use Frog's stylesheet and its `frog-*` classes, and keep the page simple and calm like Frog's own pages: a header, then cards.
5. Run `frog plugins check <folder>`, then `frog plugins install <folder>`. The first install waits for the user: tell them to approve it in Frog's window, and wait until `frog plugins list` shows it `on`. A plugin with scripts waits for the user after every change, so prefer a page without scripts when one can do the job.
6. Check your work: `frog plugins snapshot <id>` and look at the picture, `frog plugins logs <id>` for errors, and `frog plugins run <id> <command>` for commands. After each change, install again; the page reloads.
7. Never put API keys or tokens in the plugin's files. Let the user paste one into the page, and keep it with `frog.storage`, which only this plugin reads.
8. To share it, `frog plugins pack <folder>` and give the user the file and its SHA-256.

## Sharing

`frog plugins pack` makes a `.frogplugin` file, a zip of the folder, and prints its SHA-256. Publish it where people can download it over `https`, such as a GitHub release.

Anyone can install it from Frog → Plugins → Install from link, or with a link of this form, which opens Frog's review:

```
frog://plugins/install?url=<https URL of the .frogplugin>&sha256=<hex>
```

Frog downloads the file over https only, and refuses it when its SHA-256 does not match the link.

The plugin directory at <https://frog.beffa.xyz/plugins/> lists plugins people shared. To have yours listed, open an issue at <https://github.com/t1llo/frog/issues> with the link to its source and its `.frogplugin` file. Listed plugins are read before they are added, and their files are pinned by SHA-256, but they remain their authors' work: review the permissions before you install one.
