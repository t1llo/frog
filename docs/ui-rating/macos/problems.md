# Open-problems ledger (macOS)

Kept across rounds. Root causes, not symptoms. Status: `open`, `fixed, unconfirmed`, `closed`, `reopened`, `blocked: needs owner or data`. Only a judge closes an entry. Owner-reported entries (O1-O12) come first in the first improve round.

## Owner-reported (2026-11-07)

### O1. Frog menu: a long phone name breaks the Phone row
- **Root cause:** the menu row puts the device status ("OPPO Find X9 Pro is offline") as a trailing value beside the title with no line limit or truncation rule, so a long name wraps into two lines next to the one-line title.
- **Where:** Frog menu-bar menu, Phone row, light and dark.
- **Done when:** with "OPPO Find X9 Pro" offline, the row is one row height like its neighbours: the name truncates in the middle or tail on one line, or the status moves to a caption line under the title; nothing wraps beside the title.
- **Status:** fixed, unconfirmed (round 2: state on a caption line under the name, full name shown (3c336d6)). Before: reopened (round 1 judge #1 and both comparisons: the name is now cut to "OPPO Find X9… · Offline"; the fixed long-name item must show in full. New done when: the full name "OPPO Find X9 Pro" and its offline state are readable without truncation, in one row or a title plus caption line, light and dark). Earlier: (round 1: one line: name then "Offline", name truncates first (5731733)). Seen: owner report, round 0, round 1.

### O2. Window corner and sidebar corner are not concentric
- **Round 0:** the real window's corner measured about 7 pt and the sidebar's about 13 pt (8 pt in); the drawn pages show a much rounder sidebar than the real window (`chrome-*-dark`).
- **Root cause:** `FrogStyle.windowRadius` is a hard-coded guess (28 on macOS 26, 10 before) and `sidebarRadius` derives from it; the real corner macOS draws for this window style differs, so the sidebar's curve doesn't share the window's centre.
- **Where:** main window, top-left and bottom-left corners, every page, light and dark.
- **Done when:** in a crop of the window's corners the gap between the window edge and the sidebar panel stays even all the way round the curve.
- **Status:** closed (round 1: corner and sidebar read concentric in the real window). Earlier: (round 1: real corner measured 12 pt on macOS 26; sidebar 4 in with an 8 pt corner (b925a77)). Seen: owner report, round 0, round 1.

### O3. Sidebar background and page background read as two different colours
- **Root cause:** the sidebar panel draws its own fill (`FrogStyle.sidebar`) on top of a window background that differs from the page background, so the strip around and behind the sidebar is a third tone.
- **Where:** main window, every page, light and dark.
- **Done when:** the window around the sidebar and the page area read as one surface; the sidebar panel is the only distinct shape.
- **Status:** closed (round 1: one surface around the sidebar, in both comparisons). Earlier: (round 1: sidebar is a thin ink layer over the window canvas (b925a77)). Seen: owner report, round 0, round 1.

### O4. Floating panels have no shared placement or sizing concept, and can't be moved (product change)
- **Root cause:** command bar, clipboard history and window switcher each compute their own frame (`CommandBar`, `ClipboardHistoryLayout`, window switcher code) with different widths and anchors, and `FrogFloatingPanel` is created non-movable for them; no shared "panel family" placement that stores a user-chosen position.
- **Where:** command bar, clipboard history, window switcher panels, on the real screen.
- **Done when:** the three panels share one anchor (same top edge / centre line on the active screen) and related widths from one sizing rule; each can be dragged by its background like Raycast; after a drag the panel family reopens where it was put (remembered per screen across launches), with a way back to the default (e.g. reset when dragged back to the centre, or a menu/Settings action). Checked in a running debug instance, not only in UIShotsTests.
- **Status:** closed (round 1: one anchor, one width, all three move and reopen where they were put (panels-movement.txt); the switcher's search inset is J9). Earlier: (round 1: one 680 pt width, one top-centre anchor on the pointer display, drag by search line/footer, remembered per display in panel-placement.json, snap home within 24 pt + reset button (39dfaa8, 5e04351)). Seen: owner report, round 0, round 1.

### O5. LLM usage cards: uneven left/right insets and no gap between cards
- **Root cause:** the LLM usage popup (and page) lay out their cards with their own padding instead of `panelCardInset`/`panelCardGap`, so the trailing inset differs from the leading one and cards touch.
- **Where:** LLM usage menu-bar popup; check the LLM usage page too.
- **Done when:** every card has equal leading and trailing insets to the popup edge and the same gap between cards as other popups.
- **Status:** closed (round 1). Earlier: (round 1: even card insets and gaps in the popup (f414973)). Seen: owner report, round 0, round 1.

### O6. Icons not centred in buttons and tiles, especially footers
- **Root cause:** icon buttons size their symbols by font without a fixed square frame/optical centring, so symbols with uneven bounding boxes (arrows, external-link, refresh) sit off-centre in their capsules and tiles.
- **Where:** popup headers and footers (LLM usage popup's refresh/open buttons), symbol tiles in sidebar and menus, footers across popups.
- **Done when:** in close crops every icon is optically centred on both axes in its button or tile.
- **Status:** closed (round 1: no off-centre icon found). Earlier: (round 1: OpticalSymbol centres symbols by ink (dcbe870)). Seen: owner report, round 0, round 1.

### O7. Models information sheet uses a different palette
- **Round 0:** in the real window the sheet's fill is nearly the dimmed page's, with no edge, and its inner card is lighter: three close greys; the drawn sheet's corner is much larger than the real one (`chrome-models-info-dark`, `sheet-local-model-info-*`).
- **Root cause:** the sheet draws its own background/material (system sheet colour) instead of the window's surface tokens, so it looks like another app.
- **Where:** Models page → a model's information sheet, light and dark.
- **Done when:** the sheet's background, card and buttons match the window's page and card colours.
- **Status:** closed (round 1: the sheet matches the page palette; its corner is J15). Earlier: (round 1: frogSheetSurface() gives sheets the page colour (febcfe4)). Seen: owner report, round 0, round 1.

### O8. Hidden bar marks have different thicknesses
- **Root cause:** the hidden-bar divider marks are drawn at different widths/heights (or at fractional pixel positions) per mark instead of one shared mark size.
- **Where:** menu bar (hidden bar's divider items) and the Hidden bar page's preview.
- **Done when:** every divider mark has the same thickness and height and sits on whole pixels.
- **Status:** closed (round 1). Earlier: (round 1: one stroke and height, whole pixels (05f134c)). Seen: owner report, round 0, round 1.

### O9. Stay awake icon is off-centre and looks unfinished
- **Root cause:** the stay-awake symbol (custom or a cup glyph) has an uneven bounding box and is placed without optical centring in its tile; its drawing is weak at small size.
- **Where:** sidebar tile, Frog menu row tile, Stay awake page, menu-bar icon if used.
- **Done when:** a crisp symbol in the same style as the other tiles, optically centred in every tile.
- **Status:** closed (round 1: the cup is clean and centred). Earlier: (round 1: cup centred by ink, plain cup in the ring (05f134c)). Seen: owner report, round 0, round 1.

### O10. LLM usage menu-bar popup's design is weak (bars, slider, layout)
- **Root cause:** the popup reuses page-sized pieces squeezed into a narrow column: thin bars of two thicknesses, a session "—" placeholder that reads as empty, a range control that looks like a slider, and weak hierarchy between plan limits and the estimate.
- **Where:** LLM usage popup, light and dark, one and two accounts.
- **Done when:** the popup answers "how much is left and when does it reset" in one look: one bar thickness, reset times readable, clear hierarchy, chart legible, no stray controls.
- **Status:** fixed, unconfirmed (round 2: renewed rows keep columns ("0%", "Renewed"), "Account A", accounts shot with Claude as provider (6aaa488)). Before: reopened (round 1 judge #5: the two-account popup breaks its columns: account B's "Session" row has an empty bar, no % and "Renewed" pushed into the reset column; accounts read "A" and "B" and the plan chips say "Max 20×" under "OpenAI" (`popup-llm-usage-accounts-*`). Done when also: the accounts variant keeps the same columns on every row, a renewed limit reads as a full bar with its %, and account and plan labels make sense for the provider). Earlier: (round 1: popup redesigned: one meter, readable resets, bar chart, segmented range (f414973)). Seen: owner report, round 0, round 1.

### O11. Menu-bar style pickers look unfinished
- **Root cause:** the Style and Colors pickers lay their previews in a fixed three-column grid, so four styles leave one alone on a row; previews aren't drawn as real menu-bar items and the selected state is only a thin outline.
- **Where:** LLM usage page → Menu bar; System monitor page → Show in menu bar.
- **Done when:** both pickers use one tidy grid with no orphan, each preview looks like the real menu-bar item at menu-bar size on a menu-bar strip, and the selected item is unmistakable (accent ring plus label), in light and dark.
- **Status:** fixed, unconfirmed (round 2: equal 4-column grid for Style and Colors, plain strip without the band (e6ec4b9)). Before: reopened (round 1 judge #8 and comparison q3m: the Style row has 4 tiles and the Colors row 3 wider tiles, so the grid edges don't line up; a lavender/blue band under every strip reads as a stray fill (`picker-*`). Done when also: both rows share one column grid (same tile width), and the strip has no stray band). Earlier: (round 1: even rows, previews on a 24 pt menu-bar strip, accent ring + bold name (05f134c)). Seen: owner report, round 0, round 1.

### O12. System monitor doesn't show free storage (product change)
- **Root cause:** the system monitor sampler and page have no storage metric; there's nothing to show free space, its share or a 24-hour change.
- **Where:** System monitor page and its menu-bar popup.
- **Done when:** both show free space (e.g. "212 GB free"), its share of the disk, and the change against 24 hours ago (e.g. "−3.4 GB since yesterday"), from the sample data in the shots; formatted like the other values.
- **Status:** fixed, unconfirmed (round 2: the meter fills with the free share; colour still warns by used share (287ffd5)). Before: reopened (round 1 judge #2 and comparison p7k: the label says free (37%) while the bar fills to the used share (63%), in the popup, menu, page and window. Done when also: the bar and the headline describe the same quantity). Earlier: (round 1: "182 GB free · 37% of 494 GB" and "−3.4 GB since yesterday"; free-space log persisted (4875f03)). Seen: owner report, round 0, round 1.

### O13. Sidebar list slides under the search field (owner, 2026-11-07, during round 1)
- **Owner's words:** "the searchbar has a bug in the frog app sidebar under the searchbar".
- **Root cause (reading of the captures):** the sidebar's scrolling list starts right under the pinned search field and is scrolled to keep the selected page in view, so its top rows are cut off hard under the field with no gap or fade, and the first visible row sits flush against it (`chrome-system-monitor-dark`: "Writing" directly under Search, the rows above it hidden).
- **Where:** main window sidebar, every page, light and dark, at 980×680 and taller.
- **Done when:** the list keeps a clear gap under the search field; rows scrolled away fade out under it (as at the bottom edge), never a hard cut; selecting a page never leaves a row half under the field.
- **Status:** fixed, unconfirmed (round 2: band removed; a row at the edge fades as a ghost behind a gradient mask (4d9a85c)). Before: reopened (round 1 judge #4 and both comparisons: the new edge shade under the search field and above the pinned group renders as a blurred grey smudge (light: dirty streak, dark: haze), and doesn't read as a scroll edge. Done when also: the edge reads as content fading under the field (as native sidebars do), with no visible band over empty space). Earlier: (round 1: 10 pt gap under search, fade instead of hard cut (212baa5)). Seen: owner, round 1, round 1.

### O14. Frog menu: switching the Frog / System / Usage tabs is over-animated and stutters
- **Owner's words:** "when i swith between these options the animation is way to over the top also it lags/bugs a bit arround when switching" (with a crop of the tab control in the menu's header).
- **Root cause (reading of the code, to confirm):** `CompactSegments` (`Views/CompactControls.swift:209-245`) slides one thumb with `matchedGeometryEffect` on `FrogMotion.slide` while the popup swaps its whole tab body (`Views/FrogStatusMenu.swift:33-49`); the tabs have different heights, so the popup window resizes in the same frames as the thumb moves and the label colours change. Several moving things at once read as busy, and the resize plus rebuilding the new tab drops frames.
- **Where:** Frog menu-bar popup header, every tab switch, light and dark.
- **Done when:** a tab switch is one calm, short movement (the thumb only, about 150-200 ms, no overshoot), the content and the popup height change without a visible jump or stutter, and no frame shows the thumb between labels with a label still in the old colour. Checked in a running debug instance (a frame sequence or recording), not only in stills.
- **Status:** fixed, unconfirmed (round 2: only the thumb moves, 0.18 s ease-out, labels masked by the thumb, popup resizes in the same frame (3fd9a9e, 9b7200a); frame sequences from a debug instance). Before: open. Seen: owner, round 1.

## From judges

### J1. Meters of one kind come in two thicknesses
- **Root cause:** each view picks its own bar height (LLM limit bars 9 pt, system monitor meters 6 pt) instead of one meter token in `FrogChart`/`DesignSystem`.
- **Where:** LLM usage popup and page, system monitor popup and page, Frog menu's System/Usage tabs; light and dark.
- **Done when:** every meter/track of one kind has the same thickness on every surface.
- **Status:** closed (round 1). Earlier: (round 1: one 6 pt meter (f414973)). Seen: round 0, round 1.

### J2. Status footers and time formats differ between surfaces
- **Root cause:** each popup writes its own footer status and relative-time text instead of one footer status component and `RecentTimestamp` everywhere.
- **Where:** footers of the Frog menu ("● Ready"), Usage tab ("15m ago"), LLM popup (clock "15m ago"), system monitor popup ("● Live", "Measuring…"); clipboard "12 min ago" vs "15m ago"; chart axis "0" beside "$2.50".
- **Done when:** one footer status form (dot or symbol + short text) and one relative-time format in every popup and panel; axis labels formatted alike.
- **Status:** fixed, unconfirmed (round 2: footer status never cut, Settings with key caps on every tab, one axis label form (6c3de43)). Before: reopened (round 1 judge #3, #13 and both comparisons: the Usage tab footer falls back to its compact form and shows a bare "⌘ ," without "Settings" because "15 min ago" is longer; the LLM chart axis mixes "$5", "$2.50" and "$0". Done when also: every menu tab footer shows "Settings ⌘ ," at the fixed width, and one axis label format per chart). Earlier: (round 1: FrogFooterStatus (422b5cb)). Seen: round 0, round 1.

### J3. System monitor page's second column doesn't line up
- **Root cause:** the cards in the page's two-column grid size their columns by content, so the second column starts at different x per card.
- **Where:** System monitor page (GPU, Storage, Temperature), light and dark.
- **Done when:** the second-column cards share one leading edge.
- **Status:** closed (round 1). Earlier: (round 1: shared column edge (4875f03)). Seen: round 0, round 1.

### J4. The real sidebar hides rows under the pinned Frog group without a cue
- **Root cause:** the sidebar pins the Frog group (Models, Features, Settings) at the bottom and scrolls the rest behind it at 680 pt tall, with no fade or scroll cue.
- **Where:** main window at 980×680, every page (`chrome-*-dark`).
- **Done when:** at 980×680 either every sidebar row is reachable in view, or hidden rows are clearly signalled (fade/scroll edge) and the selected row is never pushed against the pinned group.
- **Status:** fixed, unconfirmed (round 2: see O13 (4d9a85c)). Before: reopened (round 1: see O13; the shade above the pinned Frog group reads as a smudge). Earlier: (round 1: soft shade at edges with rows beyond (212baa5)). Seen: round 0, round 1.

### J5. The same API estimate is charted two ways
- **Root cause:** popup/menu tab draw a smooth line with no axis, the page draws daily bars with an axis; no shared chart for one metric.
- **Where:** LLM usage popup, Frog menu Usage tab, LLM usage page.
- **Done when:** one chart form (or clearly related forms) for the estimate across surfaces, aligned to its date labels.
- **Status:** closed (round 1). Earlier: (round 1: bar chart for the estimate in popup too (f414973)). Seen: round 0, round 1.

### J6. Stay awake page has no state at a glance; a dependent switch shows on while the main switch is off
- **Root cause:** the page lists switches without a state header, and the "Keep the screen on" option stays enabled/accent while its parent is off.
- **Where:** Stay awake page, light and dark, real window.
- **Done when:** the page shows the current state (awake until / not keeping awake) at a glance, and dependent options look inactive while the main switch is off.
- **Status:** fixed, unconfirmed (round 2: status card with state, time left and switch; dependent option truly disabled (a9ae102)). Before: reopened (round 1 judge #11, #12: "Keep the screen on" still reads as on-but-broken (dim purple track, grey knob) while the main switch is off; the state is only a small "Sleeps as usual" with no glanceable status card). Earlier: (round 1: state in header, dependent options fade (d39f665)). Seen: round 0, round 1.

### J7. System monitor loading popup is 3 pt taller than the loaded one
- **Root cause:** skeleton rows have a different height than the loaded rows.
- **Where:** system monitor popup, loading vs loaded.
- **Done when:** loading and loaded popups are the same height.
- **Status:** closed (round 1). Earlier: (round 1: skeleton lines text height (4875f03)). Seen: round 0, round 1.

### J8. Clipboard panel has no preview of the selected item
- **Root cause:** the clipboard panel is a single list; long entries are truncated with no way to check before pasting.
- **Where:** clipboard history panel.
- **Done when:** the selected item's full text/image/link can be seen before pasting, inside the panel family's frame (a preview area or expansion), without breaking the shared placement concept of O4.
- **Status:** fixed, unconfirmed (round 2: rows show source app and time, preview sized to its content, "From" line (e9c7b8c)). Before: reopened (round 1 judge #14, comparison p7k: the preview pane is about 70% empty for a one-line clip; rows lost their time and show no source app; long items now truncate in the narrower list. Done when also: rows keep source app and time, and the preview uses its space (or sizes to its content) for short clips). Earlier: (round 1: list + preview card in the clipboard panel (39dfaa8)). Seen: round 0, round 1.

### J9. The window switcher's search line is not the family's search line
- **Root cause:** the window switcher builds its own `searchLine` (`Views/WindowSwitcherOverlay.swift:110-116`) instead of the shared floating-panel search header, so its magnifier and placeholder sit 3 and 8 pt further in.
- **Where:** window switcher panel vs command bar and clipboard, light and dark, real panels.
- **Done when:** with the three panels stacked (`panels-*`), the magnifier and placeholder start at the same x in all three.
- **Status:** fixed, unconfirmed (round 2: one search line geometry for all three panels (7e87feb)). Before: open. Seen: round 1 (judge #6, comparison p7k).

### J10. The Hidden bar preview doesn't look like a menu bar
- **Root cause:** `HiddenBarArrangement` (`Views/HiddenBarPage.swift:56-70`) spreads its sections with `Spacer`s across the card instead of packing the items to the right like a real menu bar; the "Shown" status floats alone below it.
- **Where:** Hidden bar page, sections preview, light and dark.
- **Done when:** the preview reads as a real menu bar: items packed to the trailing edge with menu-bar spacing, hidden sections marked by their dividers, and the status label attached to what it describes.
- **Status:** fixed, unconfirmed (round 2: preview packs items right like a real menu bar with Apple logo and clock, section names under their icons (3c5a3d1)). Before: open. Seen: round 1 (judge #7).

### J11. The Columns menu-bar style can't be read at menu-bar size
- **Root cause:** the Columns style stacks a caption under each pill, which at menu-bar height leaves about 5 pt type (`Features/MenuBarMeter.swift`).
- **Where:** menu-bar items, pickers (both features), light and dark.
- **Done when:** every caption in every menu-bar style is at least the menu bar's smallest readable size (about 9 pt), or the style drops the caption.
- **Status:** fixed, unconfirmed (round 2: no meter label under 9 pt; three readings side by side; Columns labels beside the bars (e6ec4b9)). Before: open. Seen: round 1 (judge #9).

### J12. Partly filled Spectrum and Traffic-light steps look muddy
- **Root cause:** partial steps are drawn by lowering the colour's alpha (`Ink.fill` with `strength`, `Features/MenuBarMeter.swift:100-115`), which mixes the hue with the bar behind it into olive, brown, beige or salmon.
- **Where:** menu-bar items and pickers, light and dark.
- **Done when:** every step is either a clean colour or clearly empty or partly filled (for example a clean fill to a fraction of the step), with no muddy mixed tones in light or dark.
- **Status:** fixed, unconfirmed (round 2: steps are solid or empty, five clean Spectrum colours, receding readings grey (e6ec4b9)). Before: open. Seen: round 1 (judge #10).

### J13. Stay awake and Hidden bar pages break the window's page pattern
- **Root cause:** these two pages lay out their switches without the section headers and status card the other feature pages (System monitor, LLM usage, Models) use.
- **Where:** Stay awake and Hidden bar pages, real window and drawn pages, light and dark.
- **Done when:** both pages use the same page structure as the others: a glanceable status at the top and titled sections.
- **Status:** fixed, unconfirmed (round 2: Stay awake: status card plus titled Session and Menu bar sections (a9ae102); Hidden bar: titled Menu bar status card and Hiding card, also with no organizer (3c5a3d1)). Before: open. Seen: round 1 (judge #12). Related: J6.

### J14. The Hidden bar sidebar icon is weaker than the rest
- **Root cause:** the Hidden bar tile uses a plain grey window glyph instead of a tinted, meaningful symbol like the other features.
- **Where:** sidebar, Features page, Frog menu if listed.
- **Done when:** the Hidden bar tile is tinted like its neighbours with a symbol that reads as hiding menu-bar items.
- **Status:** fixed, unconfirmed (round 2: menubar.arrow.up.rectangle tile, tinted blue (3c5a3d1)). Before: open. Seen: round 1 (judge #15).

### J15. The models information sheet's corner is not concentric with its inner card
- **Root cause:** the sheet's own corner radius and its card's radius plus inset are set independently.
- **Where:** Models page → model information sheet, light and dark.
- **Done when:** the gap between the sheet edge and the inner card is even all round each corner.
- **Status:** open (round 2: not started; macOS draws the sheet with a 12 pt corner while the inner card has 14 pt at 20 pt in, so concentric needs a change of sheet padding or card radius across all sheets). Seen: round 1 (comparison q3m only).

### J16. The Qwen model tiles use a different illustration style
- **Root cause:** the local model list shows vendor artwork for some models next to SF Symbol tiles for others.
- **Where:** Models page, local models, light and dark.
- **Done when:** every model tile uses the same tile style.
- **Status:** fixed, unconfirmed (round 2: symbol tiles for the Qwen models (5230748)). Before: open. Seen: round 1 (judge, criterion 10). Low priority.

### Capture gap (round 0)
- Round 0 had no shot of the menu-bar style pickers, the menu-bar items or the hidden bar's sections, so O8 and O11 were not seen by the judge. From round 1 the capture adds `picker-*`, `menubar-items-*` and the hidden-bar sections, and the baseline is recaptured with them for the comparison.
