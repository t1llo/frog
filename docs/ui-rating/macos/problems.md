# Open-problems ledger (macOS)

Kept across rounds. Root causes, not symptoms. Status: `open`, `fixed, unconfirmed`, `closed`, `reopened`, `blocked: needs owner or data`. Only a judge closes an entry. Owner-reported entries (O1-O12) come first in the first improve round.

## Owner-reported (2026-11-07)

### O1. Frog menu: a long phone name breaks the Phone row
- **Root cause:** the menu row puts the device status ("OPPO Find X9 Pro is offline") as a trailing value beside the title with no line limit or truncation rule, so a long name wraps into two lines next to the one-line title.
- **Where:** Frog menu-bar menu, Phone row, light and dark.
- **Done when:** with "OPPO Find X9 Pro" offline, the row is one row height like its neighbours: the name truncates in the middle or tail on one line, or the status moves to a caption line under the title; nothing wraps beside the title.
- **Status:** open. Seen: owner report, round 0.

### O2. Window corner and sidebar corner are not concentric
- **Round 0:** the real window's corner measured about 7 pt and the sidebar's about 13 pt (8 pt in); the drawn pages show a much rounder sidebar than the real window (`chrome-*-dark`).
- **Root cause:** `FrogStyle.windowRadius` is a hard-coded guess (28 on macOS 26, 10 before) and `sidebarRadius` derives from it; the real corner macOS draws for this window style differs, so the sidebar's curve doesn't share the window's centre.
- **Where:** main window, top-left and bottom-left corners, every page, light and dark.
- **Done when:** in a crop of the window's corners the gap between the window edge and the sidebar panel stays even all the way round the curve.
- **Status:** open. Seen: owner report, round 0.

### O3. Sidebar background and page background read as two different colours
- **Root cause:** the sidebar panel draws its own fill (`FrogStyle.sidebar`) on top of a window background that differs from the page background, so the strip around and behind the sidebar is a third tone.
- **Where:** main window, every page, light and dark.
- **Done when:** the window around the sidebar and the page area read as one surface; the sidebar panel is the only distinct shape.
- **Status:** open. Seen: owner report, round 0.

### O4. Floating panels have no shared placement or sizing concept, and can't be moved (product change)
- **Root cause:** command bar, clipboard history and window switcher each compute their own frame (`CommandBar`, `ClipboardHistoryLayout`, window switcher code) with different widths and anchors, and `FrogFloatingPanel` is created non-movable for them; no shared "panel family" placement that stores a user-chosen position.
- **Where:** command bar, clipboard history, window switcher panels, on the real screen.
- **Done when:** the three panels share one anchor (same top edge / centre line on the active screen) and related widths from one sizing rule; each can be dragged by its background like Raycast; after a drag the panel family reopens where it was put (remembered per screen across launches), with a way back to the default (e.g. reset when dragged back to the centre, or a menu/Settings action). Checked in a running debug instance, not only in UIShotsTests.
- **Status:** open. Seen: owner report, round 0.

### O5. LLM usage cards: uneven left/right insets and no gap between cards
- **Root cause:** the LLM usage popup (and page) lay out their cards with their own padding instead of `panelCardInset`/`panelCardGap`, so the trailing inset differs from the leading one and cards touch.
- **Where:** LLM usage menu-bar popup; check the LLM usage page too.
- **Done when:** every card has equal leading and trailing insets to the popup edge and the same gap between cards as other popups.
- **Status:** open. Seen: owner report, round 0.

### O6. Icons not centred in buttons and tiles, especially footers
- **Root cause:** icon buttons size their symbols by font without a fixed square frame/optical centring, so symbols with uneven bounding boxes (arrows, external-link, refresh) sit off-centre in their capsules and tiles.
- **Where:** popup headers and footers (LLM usage popup's refresh/open buttons), symbol tiles in sidebar and menus, footers across popups.
- **Done when:** in close crops every icon is optically centred on both axes in its button or tile.
- **Status:** open. Seen: owner report, round 0.

### O7. Models information sheet uses a different palette
- **Round 0:** in the real window the sheet's fill is nearly the dimmed page's, with no edge, and its inner card is lighter: three close greys; the drawn sheet's corner is much larger than the real one (`chrome-models-info-dark`, `sheet-local-model-info-*`).
- **Root cause:** the sheet draws its own background/material (system sheet colour) instead of the window's surface tokens, so it looks like another app.
- **Where:** Models page → a model's information sheet, light and dark.
- **Done when:** the sheet's background, card and buttons match the window's page and card colours.
- **Status:** open. Seen: owner report, round 0.

### O8. Hidden bar marks have different thicknesses
- **Root cause:** the hidden-bar divider marks are drawn at different widths/heights (or at fractional pixel positions) per mark instead of one shared mark size.
- **Where:** menu bar (hidden bar's divider items) and the Hidden bar page's preview.
- **Done when:** every divider mark has the same thickness and height and sits on whole pixels.
- **Status:** open. Seen: owner report, round 0.

### O9. Stay awake icon is off-centre and looks unfinished
- **Root cause:** the stay-awake symbol (custom or a cup glyph) has an uneven bounding box and is placed without optical centring in its tile; its drawing is weak at small size.
- **Where:** sidebar tile, Frog menu row tile, Stay awake page, menu-bar icon if used.
- **Done when:** a crisp symbol in the same style as the other tiles, optically centred in every tile.
- **Status:** open. Seen: owner report, round 0.

### O10. LLM usage menu-bar popup's design is weak (bars, slider, layout)
- **Root cause:** the popup reuses page-sized pieces squeezed into a narrow column: thin bars of two thicknesses, a session "—" placeholder that reads as empty, a range control that looks like a slider, and weak hierarchy between plan limits and the estimate.
- **Where:** LLM usage popup, light and dark, one and two accounts.
- **Done when:** the popup answers "how much is left and when does it reset" in one look: one bar thickness, reset times readable, clear hierarchy, chart legible, no stray controls.
- **Status:** open. Seen: owner report, round 0.

### O11. Menu-bar style pickers look unfinished
- **Root cause:** the Style and Colors pickers lay their previews in a fixed three-column grid, so four styles leave one alone on a row; previews aren't drawn as real menu-bar items and the selected state is only a thin outline.
- **Where:** LLM usage page → Menu bar; System monitor page → Show in menu bar.
- **Done when:** both pickers use one tidy grid with no orphan, each preview looks like the real menu-bar item at menu-bar size on a menu-bar strip, and the selected item is unmistakable (accent ring plus label), in light and dark.
- **Status:** open. Seen: owner report, round 0.

### O12. System monitor doesn't show free storage (product change)
- **Root cause:** the system monitor sampler and page have no storage metric; there's nothing to show free space, its share or a 24-hour change.
- **Where:** System monitor page and its menu-bar popup.
- **Done when:** both show free space (e.g. "212 GB free"), its share of the disk, and the change against 24 hours ago (e.g. "−3.4 GB since yesterday"), from the sample data in the shots; formatted like the other values.
- **Status:** open. Seen: owner report, round 0.

### O13. Sidebar list slides under the search field (owner, 2026-11-07, during round 1)
- **Owner's words:** "the searchbar has a bug in the frog app sidebar under the searchbar".
- **Root cause (reading of the captures):** the sidebar's scrolling list starts right under the pinned search field and is scrolled to keep the selected page in view, so its top rows are cut off hard under the field with no gap or fade, and the first visible row sits flush against it (`chrome-system-monitor-dark`: "Writing" directly under Search, the rows above it hidden).
- **Where:** main window sidebar, every page, light and dark, at 980×680 and taller.
- **Done when:** the list keeps a clear gap under the search field; rows scrolled away fade out under it (as at the bottom edge), never a hard cut; selecting a page never leaves a row half under the field.
- **Status:** open. Seen: owner, round 1.

## From judges

### J1. Meters of one kind come in two thicknesses
- **Root cause:** each view picks its own bar height (LLM limit bars 9 pt, system monitor meters 6 pt) instead of one meter token in `FrogChart`/`DesignSystem`.
- **Where:** LLM usage popup and page, system monitor popup and page, Frog menu's System/Usage tabs; light and dark.
- **Done when:** every meter/track of one kind has the same thickness on every surface.
- **Status:** open. Seen: round 0. Related: O10.

### J2. Status footers and time formats differ between surfaces
- **Root cause:** each popup writes its own footer status and relative-time text instead of one footer status component and `RecentTimestamp` everywhere.
- **Where:** footers of the Frog menu ("● Ready"), Usage tab ("15m ago"), LLM popup (clock "15m ago"), system monitor popup ("● Live", "Measuring…"); clipboard "12 min ago" vs "15m ago"; chart axis "0" beside "$2.50".
- **Done when:** one footer status form (dot or symbol + short text) and one relative-time format in every popup and panel; axis labels formatted alike.
- **Status:** open. Seen: round 0.

### J3. System monitor page's second column doesn't line up
- **Root cause:** the cards in the page's two-column grid size their columns by content, so the second column starts at different x per card.
- **Where:** System monitor page (GPU, Storage, Temperature), light and dark.
- **Done when:** the second-column cards share one leading edge.
- **Status:** open. Seen: round 0.

### J4. The real sidebar hides rows under the pinned Frog group without a cue
- **Root cause:** the sidebar pins the Frog group (Models, Features, Settings) at the bottom and scrolls the rest behind it at 680 pt tall, with no fade or scroll cue.
- **Where:** main window at 980×680, every page (`chrome-*-dark`).
- **Done when:** at 980×680 either every sidebar row is reachable in view, or hidden rows are clearly signalled (fade/scroll edge) and the selected row is never pushed against the pinned group.
- **Status:** open. Seen: round 0.

### J5. The same API estimate is charted two ways
- **Root cause:** popup/menu tab draw a smooth line with no axis, the page draws daily bars with an axis; no shared chart for one metric.
- **Where:** LLM usage popup, Frog menu Usage tab, LLM usage page.
- **Done when:** one chart form (or clearly related forms) for the estimate across surfaces, aligned to its date labels.
- **Status:** open. Seen: round 0. Related: O10.

### J6. Stay awake page has no state at a glance; a dependent switch shows on while the main switch is off
- **Root cause:** the page lists switches without a state header, and the "Keep the screen on" option stays enabled/accent while its parent is off.
- **Where:** Stay awake page, light and dark, real window.
- **Done when:** the page shows the current state (awake until / not keeping awake) at a glance, and dependent options look inactive while the main switch is off.
- **Status:** open. Seen: round 0. Related: O9.

### J7. System monitor loading popup is 3 pt taller than the loaded one
- **Root cause:** skeleton rows have a different height than the loaded rows.
- **Where:** system monitor popup, loading vs loaded.
- **Done when:** loading and loaded popups are the same height.
- **Status:** open. Seen: round 0.

### J8. Clipboard panel has no preview of the selected item
- **Root cause:** the clipboard panel is a single list; long entries are truncated with no way to check before pasting.
- **Where:** clipboard history panel.
- **Done when:** the selected item's full text/image/link can be seen before pasting, inside the panel family's frame (a preview area or expansion), without breaking the shared placement concept of O4.
- **Status:** open. Seen: round 0. Lower priority than O1-O12.

### Capture gap (round 0)
- Round 0 had no shot of the menu-bar style pickers, the menu-bar items or the hidden bar's sections, so O8 and O11 were not seen by the judge. From round 1 the capture adds `picker-*`, `menubar-items-*` and the hidden-bar sections, and the baseline is recaptured with them for the comparison.
