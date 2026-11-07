# Open-problems ledger (macOS)

Kept across rounds. Root causes, not symptoms. Status: `open`, `fixed, unconfirmed`, `closed`, `reopened`, `blocked: needs owner or data`. Only a judge closes an entry. Owner-reported entries (O1-O12) come first in the first improve round.

## Owner-reported (2026-11-07)

### O1. Frog menu: a long phone name breaks the Phone row
- **Root cause:** the menu row puts the device status ("OPPO Find X9 Pro is offline") as a trailing value beside the title with no line limit or truncation rule, so a long name wraps into two lines next to the one-line title.
- **Where:** Frog menu-bar menu, Phone row, light and dark.
- **Done when:** with "OPPO Find X9 Pro" offline, the row is one row height like its neighbours: the name truncates in the middle or tail on one line, or the status moves to a caption line under the title; nothing wraps beside the title.
- **Status:** open. Seen: owner report.

### O2. Window corner and sidebar corner are not concentric
- **Root cause:** `FrogStyle.windowRadius` is a hard-coded guess (28 on macOS 26, 10 before) and `sidebarRadius` derives from it; the real corner macOS draws for this window style differs, so the sidebar's curve doesn't share the window's centre.
- **Where:** main window, top-left and bottom-left corners, every page, light and dark.
- **Done when:** in a crop of the window's corners the gap between the window edge and the sidebar panel stays even all the way round the curve.
- **Status:** open. Seen: owner report.

### O3. Sidebar background and page background read as two different colours
- **Root cause:** the sidebar panel draws its own fill (`FrogStyle.sidebar`) on top of a window background that differs from the page background, so the strip around and behind the sidebar is a third tone.
- **Where:** main window, every page, light and dark.
- **Done when:** the window around the sidebar and the page area read as one surface; the sidebar panel is the only distinct shape.
- **Status:** open. Seen: owner report.

### O4. Floating panels have no shared placement or sizing concept, and can't be moved (product change)
- **Root cause:** command bar, clipboard history and window switcher each compute their own frame (`CommandBar`, `ClipboardHistoryLayout`, window switcher code) with different widths and anchors, and `FrogFloatingPanel` is created non-movable for them; no shared "panel family" placement that stores a user-chosen position.
- **Where:** command bar, clipboard history, window switcher panels, on the real screen.
- **Done when:** the three panels share one anchor (same top edge / centre line on the active screen) and related widths from one sizing rule; each can be dragged by its background like Raycast; after a drag the panel family reopens where it was put (remembered per screen across launches), with a way back to the default (e.g. reset when dragged back to the centre, or a menu/Settings action). Checked in a running debug instance, not only in UIShotsTests.
- **Status:** open. Seen: owner report.

### O5. LLM usage cards: uneven left/right insets and no gap between cards
- **Root cause:** the LLM usage popup (and page) lay out their cards with their own padding instead of `panelCardInset`/`panelCardGap`, so the trailing inset differs from the leading one and cards touch.
- **Where:** LLM usage menu-bar popup; check the LLM usage page too.
- **Done when:** every card has equal leading and trailing insets to the popup edge and the same gap between cards as other popups.
- **Status:** open. Seen: owner report.

### O6. Icons not centred in buttons and tiles, especially footers
- **Root cause:** icon buttons size their symbols by font without a fixed square frame/optical centring, so symbols with uneven bounding boxes (arrows, external-link, refresh) sit off-centre in their capsules and tiles.
- **Where:** popup headers and footers (LLM usage popup's refresh/open buttons), symbol tiles in sidebar and menus, footers across popups.
- **Done when:** in close crops every icon is optically centred on both axes in its button or tile.
- **Status:** open. Seen: owner report.

### O7. Models information sheet uses a different palette
- **Root cause:** the sheet draws its own background/material (system sheet colour) instead of the window's surface tokens, so it looks like another app.
- **Where:** Models page → a model's information sheet, light and dark.
- **Done when:** the sheet's background, card and buttons match the window's page and card colours.
- **Status:** open. Seen: owner report.

### O8. Hidden bar marks have different thicknesses
- **Root cause:** the hidden-bar divider marks are drawn at different widths/heights (or at fractional pixel positions) per mark instead of one shared mark size.
- **Where:** menu bar (hidden bar's divider items) and the Hidden bar page's preview.
- **Done when:** every divider mark has the same thickness and height and sits on whole pixels.
- **Status:** open. Seen: owner report.

### O9. Stay awake icon is off-centre and looks unfinished
- **Root cause:** the stay-awake symbol (custom or a cup glyph) has an uneven bounding box and is placed without optical centring in its tile; its drawing is weak at small size.
- **Where:** sidebar tile, Frog menu row tile, Stay awake page, menu-bar icon if used.
- **Done when:** a crisp symbol in the same style as the other tiles, optically centred in every tile.
- **Status:** open. Seen: owner report.

### O10. LLM usage menu-bar popup's design is weak (bars, slider, layout)
- **Root cause:** the popup reuses page-sized pieces squeezed into a narrow column: thin bars of two thicknesses, a session "—" placeholder that reads as empty, a range control that looks like a slider, and weak hierarchy between plan limits and the estimate.
- **Where:** LLM usage popup, light and dark, one and two accounts.
- **Done when:** the popup answers "how much is left and when does it reset" in one look: one bar thickness, reset times readable, clear hierarchy, chart legible, no stray controls.
- **Status:** open. Seen: owner report.

### O11. Menu-bar style pickers look unfinished
- **Root cause:** the Style and Colors pickers lay their previews in a fixed three-column grid, so four styles leave one alone on a row; previews aren't drawn as real menu-bar items and the selected state is only a thin outline.
- **Where:** LLM usage page → Menu bar; System monitor page → Show in menu bar.
- **Done when:** both pickers use one tidy grid with no orphan, each preview looks like the real menu-bar item at menu-bar size on a menu-bar strip, and the selected item is unmistakable (accent ring plus label), in light and dark.
- **Status:** open. Seen: owner report.

### O12. System monitor doesn't show free storage (product change)
- **Root cause:** the system monitor sampler and page have no storage metric; there's nothing to show free space, its share or a 24-hour change.
- **Where:** System monitor page and its menu-bar popup.
- **Done when:** both show free space (e.g. "212 GB free"), its share of the disk, and the change against 24 hours ago (e.g. "−3.4 GB since yesterday"), from the sample data in the shots; formatted like the other values.
- **Status:** open. Seen: owner report.

## From judges

(none yet)
