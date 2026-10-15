# Windows

**Windows** gives window management its own page in Frog. It is off by default.

Turn it on in **Features → Windows**, or set `feature.windows = true` in the [configuration file](configuration.md). **Windows** then appears in the sidebar.

## Sizes

These options change where layouts put windows while Windows is on. Switch Windows off and every layout lands where it always did.

- **Gap between windows** leaves space around the edge of the screen and between windows placed side by side, from 0 to 40 points. Halves, quarters, thirds, two-thirds, maximize and the centered sizes keep to it; Center and moving to another display keep the window inside it.
- **Cycle sizes when pressed again**: press Left half or Right half again while the window is still where Frog put it, and it takes two thirds of the width, then one third, then half again. Top half and Bottom half do the same with the height. Restore previous size returns to the size from before the first press.
- **Thirds run top to bottom on tall displays**: on a display that is taller than wide, such as a rotated monitor, Left third becomes the top third, Center third the middle and Right third the bottom; the two-thirds layouts follow. On by default.
- **Leave room for Stage Manager**: while Stage Manager is on, layouts keep the left 190 points of each display free so its strip of recent apps stays visible. Frog checks Stage Manager each time you use a layout, so switching it in Control Center counts from the next press. On by default.

The same settings are in the [configuration file](configuration.md) as `windows.gap`, `windows.cycle-sizes`, `windows.portrait-thirds` and `windows.respect-stage-manager`.

## Layout shortcuts

The page lists every layout Frog can apply to the front window: halves, quarters, thirds and two-thirds, three centered sizes, maximize, minimize, center, restore the previous size, full screen, and moving a window to the next or previous display. Layouts with a shortcut are listed first.

Click a row's shortcut field and press a key combination to assign it. Recording a shortcut switches the layout on; the switch next to it turns the layout off and on again without forgetting the shortcut. The same layouts are available in the command bar: type a name such as "Left half".

Layout shortcuts run while **Windows** or **Shortcuts** is on, so you can switch off Shortcuts (applications and Mac actions) and keep your window layouts. While Windows is on, Shortcuts shows only its Application and Other segments and links to this page; switch Windows off and the layouts appear under **Shortcuts → Windows** again, with the same shortcuts.

## Window switcher

The ⌘Tab window switcher, which switches between individual windows rather than apps, is a separate feature. **Related → Window switcher → Open in Features** on the Windows page takes you to its card.

## Accessibility

Frog needs Accessibility to move windows. It does not record your screen. Until access is granted, the page shows a notice and an **Allow Accessibility** button that opens the system prompt and **System Settings → Privacy & Security → Accessibility**.
