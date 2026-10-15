# Windows

**Windows** gives window management its own page in Frog. It is off by default.

Turn it on in **Features → Windows**, or set `feature.windows = true` in the [configuration file](configuration.md). **Windows** then appears in the sidebar.

## Sizes

These options change where layouts put windows while Windows is on. Switch Windows off and every layout lands where it always did.

- **Gap between windows** leaves space around the edge of the screen and between windows placed side by side, from 0 to 40 points. Halves, quarters, thirds, two-thirds, maximize and the centered sizes keep to it; Center and moving to another display keep the window inside it.
- **Cycle sizes when pressed again**: press Left half or Right half again while the window is still where Frog put it, and it takes two thirds of the width, then one third, then half again. Top half and Bottom half do the same with the height. Restore previous size returns to the size from before the first press.
- **Thirds run top to bottom on tall displays**: on a display that is taller than wide, such as a rotated monitor, Left third becomes the top third, Center third the middle and Right third the bottom; the two-thirds layouts follow. On by default.
- **Leave room for Stage Manager**: while Stage Manager is on, layouts keep the left 190 points of each display free so its strip of recent apps stays visible. Frog checks Stage Manager each time you use a layout, so switching it in Control Center counts from the next press. On by default.

The same settings are in the [configuration file](configuration.md) as `windows.gap`, `windows.cycle-sizes`, `windows.portrait-thirds` and `windows.respect-stage-manager`; drag to snap is `windows.drag-to-snap` and `windows.restore-on-drag`.

## Layout shortcuts

The page lists every layout Frog can apply to the front window: halves, quarters, thirds and two-thirds, three centered sizes, maximize, minimize, center, restore the previous size, full screen, and moving a window to the next or previous display. Layouts with a shortcut are listed first.

Click a row's shortcut field and press a key combination to assign it. Recording a shortcut switches the layout on; the switch next to it turns the layout off and on again without forgetting the shortcut. The same layouts are available in the command bar: type a name such as "Left half".

Layout shortcuts run while **Windows** or **Shortcuts** is on, so you can switch off Shortcuts (applications and Mac actions) and keep your window layouts. While Windows is on, Shortcuts shows only its Application and Other segments and links to this page; switch Windows off and the layouts appear under **Shortcuts → Windows** again, with the same shortcuts.

## Suggested shortcuts

**Use suggested shortcuts** above the list gives every layout that has no shortcut yet the one below, and the cheat sheet and the layout picker their shortcuts. A layout or command that already has a shortcut keeps it, even when it is switched off. A combination that another Frog shortcut already uses, including the window switcher's, is skipped, and the line under the button names what was skipped. Press it again later and it adds only what is still free.

| Layout | Shortcut |
| --- | --- |
| Left half, Right half, Top half, Bottom half | ⌃⌥←, ⌃⌥→, ⌃⌥↑, ⌃⌥↓ |
| Top-left, Top-right, Bottom-left, Bottom-right quarter | ⌃⌥U, ⌃⌥I, ⌃⌥J, ⌃⌥K |
| Left third, Center third, Right third | ⌃⌥D, ⌃⌥F, ⌃⌥G |
| Left two-thirds, Right two-thirds | ⌃⌥E, ⌃⌥T |
| Maximize on display | ⌃⌥↩ |
| Center | ⌃⌥C |
| Restore previous size | ⌃⌥⌫ |
| Move to next display, Move to previous display | ⌃⌥⌘→, ⌃⌥⌘← |
| Window cheat sheet | ⌃⌥/ |
| Arrange window… (layout picker) | ⌃⌥W |

Minimize, full screen and the centered sizes get no suggestion. VoiceOver uses Control-Option for its own commands; while VoiceOver is on, the page says so after you press the button.

## Drag to snap

Switch on **Snap → Drag to screen edges** to arrange windows with the mouse. It is off by default and works only while Windows is on. Drag a window by its title bar and let go at the edge of the screen:

- **Left or right edge**: the window fills the left or right half.
- **Top edge**: the window fills the display (Maximize on display).
- **A corner**: the window fills that quarter. Each corner is a 20-point square.
- **Bottom edge**: the window fills the third under the pointer: Left third, Center third or Right third.

An edge counts while the pointer is within 5 points of it. While the pointer is in a zone, a tinted area shows where the window will go; move away and it disappears. Press Escape before letting go to keep the window where macOS drops it.

The window lands on the display under the pointer, with the same gap, thirds and Stage Manager room as the shortcuts, and **Restore previous size** undoes it. An edge or corner shared with another display only counts once the pointer has rested there for 0.3 seconds, so dragging a window across to the other display never snaps it on the way. Frog's own windows, full-screen windows and a drag that resizes a window are never snapped.

**Restore size when dragged away** (on by default): drag a window out of the place Frog put it and, after 10 points, it gets back the size it had before, with the pointer at the same spot across its width.

### macOS's own tiling

From macOS 15, macOS tiles windows dragged to a screen edge by itself. While that is on, Frog's edges and corners pause so the two do not fight over the window, and the Snap section says so. To use Frog's edges instead, open **System Settings → Desktop & Dock** (the page's **Open Desktop & Dock** button goes there) and, under **Windows**, turn off **Drag windows to screen edges to tile**. Frog reads this setting and never changes it. On macOS 14 there is no such setting and Frog's edges always work.

Frog notices a window drag without recording your clicks: a click costs nothing, and only once the pointer has moved does Frog look at the window under it, a few times at most. See [privacy](privacy.md).

## Layout picker

The layout picker is the easiest way to arrange a window without learning any shortcut. Switch on **Snap → Layout picker** and record a shortcut next to it (**Use suggested shortcuts** gives it ⌃⌥W). It is off by default and works only while Windows is on.

Open it in any of three ways: press its shortcut, choose **Arrange window…** in the Frog menu, or type "arrange" in the command bar. It arranges the window that was in front: the front app's focused window, or, when Frog itself is in front, the app you used just before. If there is none, the panel says so; click a window and open it again.

The panel opens in the middle of the display that holds the window. It shows the layouts as small pictures in rows of four, grouped into halves, quarters, thirds, sizes, displays and undo, each with its shortcut if it has one. Minimize and full screen are not offered.

- The arrow keys move the selection; hovering a tile selects it too. While a layout is selected, a tinted area on screen shows where the window would go. For **Restore previous size** it shows the size the window returns to, if Frog moved it before.
- Type to filter the layouts by name: "two" leaves the two-thirds layouts.
- Return or a click applies the selected layout; Escape, ⌘W, a click outside or the shortcut again closes the panel.

The panel never takes the focus from the app you are in. Layouts applied from it use the same gaps as the shortcuts, and **Restore previous size** returns the window to where it was. A half is not cycled through other sizes from the picker.

## Cheat sheet

Record a shortcut under **Cheat sheet → Show window shortcuts while holding**. Hold it and a panel lists every layout and window command that has a shortcut, grouped into halves, quarters, thirds, sizes, displays and undo, each with a small picture of where it puts the window. Release the shortcut and the panel closes. It works over full-screen apps and never takes the focus from the app you are in. The cheat sheet has no shortcut until you give it one, and works only while Windows is on.

## Window switcher

The ⌘Tab window switcher, which switches between individual windows rather than apps, is a separate feature. **Related → Window switcher → Open in Features** on the Windows page takes you to its card.

## Accessibility

Frog needs Accessibility to move windows. It does not record your screen. Until access is granted, the page shows a notice and an **Allow Accessibility** button that opens the system prompt and **System Settings → Privacy & Security → Accessibility**.
