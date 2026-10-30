# Windows

Two plugins arrange and switch windows. Both need Accessibility; neither records the screen.

- **Windows** snaps and tiles windows with keys, by dragging, or from a picker. Off by default.
- **Window switcher** switches between windows rather than apps. On by default.

Turn either on or off in **Plugins**, or with `frog plugins enable windows` / `frog plugins disable window-switcher`.

## Layouts

The **Layouts** section lists every layout as a small picture with its shortcut, two to a row: halves, quarters, thirds and two-thirds, three centered sizes, maximize, center, minimize, full screen, next and previous display, and Restore previous size. Record a shortcut to turn a layout on; clear it to turn it off. The shortcuts are shared with the Shortcuts plugin, so they work while either is on.

**Suggested shortcuts** in the page header gives every layout without a shortcut the one below, where it is free. A shortcut another Frog shortcut uses, the window switcher's included, is skipped, and the page says which.

| Layout | Shortcut |
| --- | --- |
| Left, right, top, bottom half | ⌃⌥←, ⌃⌥→, ⌃⌥↑, ⌃⌥↓ |
| Top-left, top-right, bottom-left, bottom-right | ⌃⌥U, ⌃⌥I, ⌃⌥J, ⌃⌥K |
| Left, center, right third | ⌃⌥D, ⌃⌥F, ⌃⌥G |
| Left, right two-thirds | ⌃⌥E, ⌃⌥T |
| Maximize, center, restore | ⌃⌥↩, ⌃⌥C, ⌃⌥⌫ |
| Next, previous display | ⌃⌥⌘→, ⌃⌥⌘← |
| Cheat sheet, layout picker | ⌃⌥/, ⌃⌥W |

VoiceOver uses ⌃⌥ for its own commands; while it runs, the page says so.

## Snap

- **Drag to screen edges**: let a window go at the left or right edge for a half, a corner for a quarter, the top for the whole display, the bottom for the third under the pointer. A tint shows where it lands; Escape keeps the window where macOS drops it. An edge shared with another display counts after the pointer rests there for 0.3 seconds.
- **Restore size when dragged away**: a window Frog placed gets its earlier size back once dragged 10 points away.
- **Zones while holding Shift**: Off, halves, thirds, quarters, or main and side. Hold Shift while dragging and let go over a zone.

From macOS 15, macOS tiles windows at the edges itself. While that is on, Frog's edges pause and the section says so, with a button to **System Settings → Desktop & Dock**. Shift zones keep working. Frog reads these settings and never changes them. Frog's own windows, full-screen windows and resizes are never snapped.

## Panels

- **Layout picker**: every layout as a picture, opened by its shortcut, **Arrange window…** in the Frog menu or the command bar. Arrows, typing and Return choose; Escape closes. It never takes the focus from the app in front.
- **Cheat sheet**: hold its shortcut to see every window shortcut.

## Sizes

- **Gap between windows**, 0 to 40 points.
- **Cycle sizes when pressed again**: a half pressed again becomes ⅔, then ⅓.
- **Thirds top to bottom on tall displays**.
- **Leave room for Stage Manager**: keeps the left 190 points free while Stage Manager is on.

## Window switcher

Hold ⌘ and press Tab: every window of every app in a list, most recently used first, Frog's own included while its window is open. Tab and the arrows move, Shift goes back, typing searches, releasing ⌘ switches. Escape closes. The list opens without animation; the window list and app icons are cached while the switcher runs and dropped when it stops. Icons are drawn once at row size, 6.4 KB each, at most 64 of them (410 KB).

The page sets the shortcut and says what stops the switcher: Accessibility, another shortcut on the same chord, a password prompt in another app, or a locked session.

## config.toml

```toml
[windows]
gap = 0
cycle-sizes = false
portrait-thirds = true
respect-stage-manager = true
drag-to-snap = false
restore-on-drag = true
zone-overlay = false
zones = "thirds"             # halves, thirds, quarters, main-side
layout-picker = false
# layout-picker-shortcut = "ctrl+alt+w"     none until you set one
# cheat-sheet-shortcut = "ctrl+alt+slash"

[window-switcher]
shortcut = "cmd+tab"
```

A missing key takes its default. The first time Frog runs with these plugins, it copies the settings it kept before into these tables. Layout shortcuts are rules, shown in the [Shortcuts](configuration.md) table.

## Actions

Run with `frog run <id>`, from the command bar or a shortcut.

| Action | What it does |
| --- | --- |
| `windows.<layout>` | The front window to that layout: `windows.left-half`, `windows.maximize-on-display`, `windows.move-to-next-display` and the others, named after the layout |
| `windows.list [--app]` | Open windows with id, app, title, frame and display; JSON with `--json` |
| `windows.focus [--app] [--title] [--id]` | Brings the window forward |
| `windows.move --to <layout> [--app] [--title] [--id]` | That window to a layout, such as `left-half` |
| `windows.arrange` | Shows the layout picker, while it is on |
| `window-switcher.show` | Opens the list without holding a key: Return switches, Escape closes |

Without `--app`, `--title` or `--id`, the actions use the focused window of the app in front.
