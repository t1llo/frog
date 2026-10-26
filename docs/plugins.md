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
| `links` | Open `https` links in your browser. |
| `network` | Send requests with `frog.fetch` to the hosts in `hosts`, and only those. |
| `ai` | Send text to the AI model your Writing rules use by default. A cloud model's provider bills you for it. |
| `scripts` | Run the shell scripts listed in `scripts`, with your user's full access to this Mac. Install a plugin with scripts only when you trust its author and have read the scripts. |

What the sandbox enforces:

- The page loads only from its own folder, at `frog-plugin://<id>/`. Every other address is blocked, including links, frames, forms, `fetch`, WebSockets and WebRTC; network requests go through `frog.fetch`, which Frog checks against `hosts`.
- The page has no cookies or shared website data, and cannot leave its folder or navigate elsewhere.
- Plugins cannot read Frog's settings, notes, history, keys or other plugins' storage.
- Frog records the permissions, hosts and script contents you approved. An update that asks for more, adds a host or changes a script waits for you to review it again; any other update applies directly.
- Only you can approve or turn on a plugin, in Frog's window. The `frog` command can install one for review, but not approve it.

## The `frog` object

Every function returns a promise. A call without the permission it needs fails with an error that names the permission.

```js
await frog.storage.get("key")            // the stored value, or null
await frog.storage.set("key", value)     // any JSON value; 5 MB per plugin in all
await frog.storage.remove("key")
await frog.storage.keys()

await frog.clipboard.readText()          // clipboard-read
await frog.clipboard.writeText("text")   // clipboard-write

await frog.notify("Title", "Body")       // notifications
await frog.openURL("https://…")          // links

const response = await frog.fetch("https://api.github.com/…", {
  method: "GET", headers: {}, body: "", as: "text"   // as: "text", "json" or "base64"
})                                       // network: { status, headers, body }

await frog.ai("Summarize in one sentence:", text)    // ai: the model's answer as text

const result = await frog.run("stats", { args: ["--short"], input: "text" })
                                         // scripts: { output, status, truncated }

frog.on("command", (id) => { … })        // a command bar row was chosen
frog.on("show", () => { … })             // the page came into view
frog.show()                              // bring the plugin's page forward
frog.close()                             // after a command with "show": false
frog.info                                // { id, name, version, permissions, frog }
```

Scripts run with `/bin/zsh` from the plugin's data folder, receive `args` as `$1`, `$2` and so on, and find `input` in the `FROG_INPUT` environment variable. They stop after 60 seconds, and their output is cut at 1 MB.

`console.log`, errors and rejected promises go to the plugin's log, which `frog plugins logs <id>` prints.

## Looking like Frog

Frog sets these CSS variables on the page, for the light and dark appearance and the theme you chose: `--frog-ink`, `--frog-muted`, `--frog-canvas`, `--frog-surface`, `--frog-border`, `--frog-accent`, `--frog-critical`, `--frog-font`. Link `/_frog/frog.css` for Frog's buttons, inputs, cards and type:

```html
<link rel="stylesheet" href="/_frog/frog.css">
```

## Building one with an AI agent

With agent access on (Settings → Agents) and the Frog skill installed, ask your agent for the feature you want, such as "build me a Frog plugin that shows my open GitHub pull requests". It uses these commands:

```
frog plugins new <folder> --name "Name"   start a plugin from a template
frog plugins check <folder>               check the manifest and files
frog plugins install <folder>             install or update it for your review
frog plugins logs <id>                    the page's console and errors
frog plugins snapshot <id>                a picture of the page, to check its layout
frog plugins pack <id> [--output file]    a .frogplugin file to share, with its SHA-256
frog plugins list                         installed plugins and their state
frog plugins remove <id>                  move a plugin to the Trash
```

Your first install of a plugin waits for you in Frog → Plugins. After you approve it, the agent's updates apply while they ask for nothing new.

## Sharing

`frog plugins pack` makes a `.frogplugin` file, a zip of the folder, and prints its SHA-256. Publish it where people can download it over `https`, such as a GitHub release.

Anyone can install it from Frog → Plugins → Install from link, or with a link of this form, which opens Frog's review:

```
frog://plugins/install?url=<https URL of the .frogplugin>&sha256=<hex>
```

The plugin directory at <https://frog.beffa.xyz/plugins/> lists plugins people shared. To have yours listed, open an issue at <https://github.com/t1llo/frog/issues> with the link to its source and its `.frogplugin` file. Listed plugins are read before they are added, and their files are pinned by SHA-256, but they remain their authors' work: review the permissions before you install one.
