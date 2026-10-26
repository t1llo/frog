# Windows

**Windows** gives window management its own page in Frog. It is off by default.

Turn it on in **Features → Windows**, or set `feature.windows = true` in the [configuration file](configuration.md). **Windows** then appears in the sidebar.

## First setup

The first time you open the Windows page, a card at the top asks **How do you want to arrange windows?**

- **Snap**: drag windows to screen edges, or pick a layout. Nothing moves by itself. This turns on [drag to snap](#drag-to-snap), **Restore size when dragged away**, [zones while holding Shift](#zones-while-holding-shift) and the [layout picker](#layout-picker).
- **Add suggested shortcuts (⌃⌥ with arrows and letters)**, checked by default, also gives the layouts, the cheat sheet and the layout picker the [suggested shortcuts](#suggested-shortcuts), where they are free.
- **Set up myself** hides the card and changes nothing; every setting stays on the page below.

After **Snap**, the card says what is on and how many shortcuts were added. **Undo** puts the Windows settings back as they were; shortcuts that were added stay and can be cleared under **Layout shortcuts**. The confirmation goes away when you leave the page, and the card does not come back once you have chosen. Frog saves the choice as `setupChoice` in `config.json`.

## Walkthrough

Snap is the simple way to use Windows: Frog moves a window only when you ask.

1. Turn on **Features → Windows**, open the **Windows** page, choose **Snap** on the card and keep the shortcuts checkbox ticked. If the page asks for Accessibility, allow it first.
2. Drag a window by its title bar to the left edge of the screen and let go: it fills the left half. Drag it to a corner for a quarter, to the top to fill the display, or to the bottom for the third under the pointer. A tinted area shows where it will go before you let go.
3. Drag it away again: it gets back its earlier size.
4. Hold Shift while dragging: zones cover the display, by default the three thirds. Let go over one to fill it. On macOS 15 and later with macOS's own edge tiling on, this is how you use Frog's zones.
5. Press ⌃⌥W: the layout picker shows every layout as a small picture. Use the arrows and Return, or type a name such as "third".
6. Press ⌃⌥← or ⌃⌥→ for the halves, ⌃⌥D, ⌃⌥F and ⌃⌥G for the thirds, ⌃⌥↩ to fill the display and ⌃⌥⌫ to go back to the earlier size.
7. Hold ⌃⌥/ to see all your window shortcuts at once.
8. Under **Sizes**, add a gap between windows, or let a half shortcut pressed again cycle through ⅔ and ⅓.

Everything here works on several displays: a window snaps on the display under the pointer, and **Move to next display** (⌃⌥⌘→) sends it to the next one.

## Sizes

These options change where layouts put windows while Windows is on. Switch Windows off and every layout lands where it always did.

- **Gap between windows** leaves space around the edge of the screen and between windows placed side by side, from 0 to 40 points. Halves, quarters, thirds, two-thirds, maximize and the centered sizes keep to it; Center and moving to another display keep the window inside it.
- **Cycle sizes when pressed again**: press Left half or Right half again while the window is still where Frog put it, and it takes two thirds of the width, then one third, then half again. Top half and Bottom half do the same with the height. Restore previous size returns to the size from before the first press.
- **Thirds run top to bottom on tall displays**: on a display that is taller than wide, such as a rotated monitor, Left third becomes the top third, Center third the middle and Right third the bottom; the two-thirds layouts follow. On by default.
- **Leave room for Stage Manager**: while Stage Manager is on, layouts keep the left 190 points of each display free so its strip of recent apps stays visible. Frog checks Stage Manager each time you use a layout, so switching it in Control Center counts from the next press. On by default.

The same settings are in the [configuration file](configuration.md) as `windows.gap`, `windows.cycle-sizes`, `windows.portrait-thirds` and `windows.respect-stage-manager`; drag to snap is `windows.drag-to-snap` and `windows.restore-on-drag`, and the Shift zones are `windows.zone-overlay` and `windows.zone-grid`.

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

**Restore size when dragged away** (on by default): drag a window out of the place Frog put it and, after 10 points, it gets back the size it had before, with the pointer at the same spot across its width. Let go away from the edges and **Restore previous size** has nothing left to undo; let go on another edge and it returns the window to where it was before Frog first moved it.

### Zones while holding Shift

Switch on **Snap → Show zones while holding Shift** and hold Shift while you drag a window. Zones cover the display under the pointer, each named after its layout; the one under the pointer lights up and a tinted area shows where the window will go, with your gap. Let go over a zone to apply it. Release Shift to hide the zones and go back to the edges; press Escape to keep the window where macOS drops it. The zones follow the pointer to another display.

Choose the zones under **Snap → Zones**:

- **Halves**: Left half, Right half.
- **Thirds** (the default): Left third, Center third, Right third.
- **Quarters**: the four quarters.
- **Main and side**: Left two-thirds and Right third.

On a tall display with **Thirds run top to bottom on tall displays** on, thirds and main and side stack from top to bottom. Shift zones work with drag to screen edges switched off too, and while macOS's own edge tiling is on (see below).

### macOS's own tiling

From macOS 15, macOS tiles windows dragged to a screen edge by itself. While that is on, Frog's edges and corners pause so the two do not fight over the window, and the Snap section says so. While **Drag windows to menu bar to fill screen** is on, which it is by default, Frog's top edge and top corners pause too, even with edge tiling off. Hold Shift while dragging to use Frog's zones instead: macOS tiles with Option, not Shift. At the outer edges of the screen, within 6 points, macOS still tiles a window you let go there, even with Shift held, so Frog lights no zone and applies nothing there; let go a little further in and Frog's zone applies. An edge that meets another display is not an outer edge. The top edge counts only while **Drag windows to menu bar to fill screen** is on, and while **Hold ⌥ key while dragging windows to tile** is on, holding Option leaves the whole drag to macOS. Frog reads these settings each time the zones show, so a change in Desktop & Dock counts from the next drag. To use Frog's edges instead, open **System Settings → Desktop & Dock** (the page's **Open Desktop & Dock** button goes there) and, under **Windows**, turn off **Drag windows to screen edges to tile**, and for the top edge **Drag windows to menu bar to fill screen**. Frog reads these settings and never changes them. On macOS 14 there is no such setting and Frog's edges always work.

Frog notices a window drag without recording your clicks: a click costs nothing, and only once the pointer has moved does Frog look at the window under it, a few times at most. See [privacy](privacy.md).

## Layout picker

The layout picker is the easiest way to arrange a window without learning any shortcut. Switch on **Snap → Layout picker** and record a shortcut next to it (**Use suggested shortcuts** gives it ⌃⌥W). It is off by default and works only while Windows is on.

Open it in any of three ways: press its shortcut, choose **Arrange window…** in the Frog menu, or type "arrange" in the command bar. It arranges the window that was in front: the front app's focused window, or, when Frog itself is in front, the app you used just before. If there is none, the panel says so; click a window and open it again.

The panel opens in the middle of the display that holds the window. It shows the layouts as small pictures in rows of four, grouped into halves, quarters, thirds, sizes, displays and undo, each with its shortcut if it has one. Minimize and full screen are not offered.

- The arrow keys move the selection; moving the pointer over a tile selects it too. While a layout is selected, a tinted area on screen shows where the window would go. For **Restore previous size** it shows the size the window returns to, if Frog moved it before.
- Type to filter the layouts by name: "two" leaves the two-thirds layouts.
- Return or a click applies the selected layout; Escape, ⌘W, a click outside or the shortcut again closes the panel.

The panel never takes the focus from the app you are in. Layouts applied from it use the same gaps as the shortcuts, and **Restore previous size** returns the window to where it was. A half is not cycled through other sizes from the picker.

## Cheat sheet

Record a shortcut under **Cheat sheet → Show window shortcuts while holding**. Hold it and a panel lists every layout and window command that has a shortcut, grouped into halves, quarters, thirds, sizes, displays and undo, each with a small picture of where it puts the window. Release the shortcut and the panel closes. It works over full-screen apps and never takes the focus from the app you are in. The cheat sheet has no shortcut until you give it one, and works only while Windows is on.

## Window switcher

The ⌘Tab window switcher, which switches between individual windows rather than apps, is a separate feature with its own **Window switcher** page. Turn it on in **Features**.

## Accessibility

Frog needs Accessibility to move windows. It does not record your screen. Until access is granted, the page shows a notice and an **Allow Accessibility** button that opens the system prompt and **System Settings → Privacy & Security → Accessibility**.
