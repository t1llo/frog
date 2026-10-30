# Architecture

Frog is a small core and a set of plugins. The core owns the window, the menu-bar item, configuration,
permissions, models, the action registry and the agent socket. Everything a person uses (Writing, Dictation,
the command bar, Stay awake…) is a plugin that can be turned off, and a plugin that is off costs nothing: it
is not created, holds no monitors, shortcuts, timers or status items.

```
FrogApp
├── Kernel/      FrogPlugin, PluginHost, PluginContext, actions and parameters, menu contributions
├── Plugins/     one file or folder per built-in plugin: <Name>Plugin.swift and what only it uses
├── Features/    controllers a plugin owns (command bar, writing bubble, phone, history log…)
├── Platform/    macOS services shared by plugins (Accessibility, selection, hotkeys, windows, audio)
├── Agents/      the `frog` commands and their socket server
├── Community/   third-party plugins: runtime, web host, registry
├── Views/       pages, the main window and the design system (Views/Design)
└── AppModel     the shared model the kernel hands to plugins as `legacy`, shrinking as plugins take over
FrogCore         models, config engine, persistence, Keychain, LLM and speech clients (no AppKit)
FrogUsage        LLM usage readers
FrogAgent / FrogCLI  the `frog` command and its socket protocol
```
## Plugins

A built-in plugin is a class conforming to `FrogPlugin` with a static `PluginInfo`
(id, name, symbol, tint, category, one-line summary, default on/off, permissions it needs). The host creates
it when it is turned on and calls `start()`; turning it off calls `stop()` and drops it.

A plugin contributes through a few small surfaces, all optional:

| Surface | What it is |
| --- | --- |
| `page` | Its page in the main window, found in the sidebar under its category |
| `actions` | Things it can do, with typed parameters. One action is reachable from the command bar, a keyboard shortcut, the menu bar and `frog run` alike |
| `menu` | Rows or a tab in the Frog menu-bar popup |
| status item | Its own menu-bar item, created through the context, only when the user wants it |
| settings | A `ConfigSection` struct stored as `[<plugin-id>]` in `~/.config/frog/config.toml` |

Plugins never reach into each other or into the app delegate. What they share comes from `PluginContext`:
settings, actions, hotkeys, notifications, the selection service, clipboard, text and speech models,
history, status items and error reporting.

Third-party plugins (a folder with `plugin.json` and web files) are hosted by the Plugins core page and
adapted to the same surfaces: their page, their commands as actions, their settings in their own table.

## Actions: one registry for people and agents

Every action has an id `<plugin>.<name>` (`dictation.toggle`, `windows.left-half`, `stay-awake.on`),
a title, a symbol and typed parameters. The same registry feeds:

- the command bar (actions marked for it),
- Shortcuts, which binds a key to any action with fixed parameters — the trigger → action model,
- the menu bar,
- agents: `frog actions` lists every action of the plugins that are on, `frog run <id> --param value`
  runs one and answers text or `--json`.

Anything a person can do in Frog has an action, so an agent can do it too.

## Configuration

One file, `~/.config/frog/config.toml`: core keys at the top, `[plugins]` turns plugins on and off, and
each plugin has its own table. Frog watches the file and applies valid edits at once; invalid edits are
reported and the running configuration stays. A plugin's table is written once from the older settings the
first time the plugin starts, and from then on the table decides. Writing rules and providers are still kept
in `config.json` beside it. Secrets stay in the Keychain. See [config-format.md](config-format.md).

## Window and menu bar

Frog lives in the menu bar. While its window is open it also shows in the Dock and in ⌘-Tab, and returns
to the menu bar only when the window closes. The Frog menu-bar popup is composed from what plugins
contribute; plugins with a readout (LLM usage, System monitor) show it inside Frog's popup by default and
may add their own menu-bar item when the user turns that on.

## Speed

- Launch starts only plugins that are on; heavy work (model loading, catalog scans) is deferred until first use.
- Quitting stops every plugin, waiting at most 2 seconds, so a plugin that hangs cannot keep Frog open.
- Keyboard surfaces (command bar, clipboard history, window switcher) open in one frame with no animation.
- Models load on first use, are kept warm for a configurable idle time and prewarmed when a dictation key
  goes down; a Writing rule loads its local model while it reads the selection. After loading, each model
  runs once on nothing (a second of silence, one token) so that its first real request is not the slow one.
  Idle models unload when macOS reports memory pressure, and MLX keeps at most 20 MB of freed buffers.
- Views observe with `@Observable` so a change redraws only the views that read it.
