# UI rating macOS, round 0 (baseline): capture 92db0ba

Judged from the screenshots in `docs/ui-rating/macos/shots/92db0ba/` against `docs/ui-rating/criteria.md`, with the competitor set in `docs/ui-rating/competitors/`. Fixed clock 2026-11-07 13:40. File names below are relative to the shots folder. Pixel positions are in the image's own pixels (2x for drawn shots, 1x for `chrome-*` and `panels-*`).

## 1. Scores

| # | Criterion | Weight | Score | Reason |
|---|---|---|---|---|
| 1 | Coherence of one system | high | 6.5 | Popups, menu and panels share one frame, header and keycap footer (`menu-frog-*`, `popup-*`, `clipboard-*`, `window-switcher-*`). But the LLM popup's cards sit off-centre while the others are centred (`popup-llm-usage-*` vs `popup-system-monitor-*`). Meters come in two thicknesses. The footer status reads five different ways. The same API estimate is a line in the popup and bars on the page (`popup-llm-usage-*` vs `page-usage-*`). Sidebar and window corners are not concentric (`chrome-*-dark`). The real Models sheet barely separates from the page (`chrome-models-info-dark`). |
| 2 | Alignment and spacing precision | high | 6.0 | LLM popup cards span x 50–618 in a 680 px image: 0 px inset on the left, 12 px on the right. Every other popup is 6/6 (`popup-llm-usage-light`). The second column sits at three x positions on one page: GPU 1208, Storage 1225, Temperature 1200 (`page-systemMonitor-light`). The "7d" picker sits below the "API estimate" baseline (`popup-llm-usage-*`, `menu-llm-usage-*`). The phone value wraps to two lines (`menu-frog-*`). |
| 3 | Menu-bar popups at a glance | high | 7.0 | The system monitor and LLM popups answer their question with clear values, resets and pace (`popup-system-monitor-*`, `popup-llm-usage-*`). The fixed long-name state fails: "OPPO Find X9 Pro / is offline" breaks over two grey lines in the Frog menu (`menu-frog-light`, `menu-frog-dark`). Storage reads as used, not free. |
| 4 | Floating panels as one family | high | 4.0 | Three anchors: clipboard top at y 210, command bar and switcher centred near y 555. Three unrelated widths: 680, 520, 500 (`panels-placement.png`). The switcher has no search field (`panels-window-switcher.png`). Only the command bar can really be dragged and reopens where it was put. Clipboard and switcher have no drag region and reopen at their default place (`panels-movement.txt`, `panels-movement.png`). |
| 5 | Menu-bar item designs and how you choose them | medium | 3.0 | Not in any shot. The system monitor page is cut off at a "Menu bar" heading (`page-systemMonitor-*`, bottom edge). The LLM usage page ends at "Models". The Hidden bar page has toggles only, with no picture of the bar or its sections (`page-menuBar-*`, `chrome-hidden-bar-dark`). There are no menu-bar crops, so nothing shows that the items look crafted or that the picker is a tidy grid of previews. |
| 6 | Data usefulness | medium | 6.0 | LLM usage is good: limits, pace, reset times, cost, token breakdown (`page-usage-*`, `popup-llm-usage-*`). The system monitor shows storage used ("312 GB of 494 GB") instead of free space and its share. Nothing anywhere shows a change against 24 hours ago (`popup-system-monitor-*`, `page-systemMonitor-*`). Formats drift: "15m ago" vs "12 min ago" vs "Resets in 2 hr"; the axis reads "0" next to "$2.50" and "$5" (`page-usage-light`). |
| 7 | Typography and hierarchy | medium | 7.0 | One scale with clear title, subtitle and value roles, and values on the trailing edge (`page-*`, `sheet-local-model-info-*`). Page titles are heavy and tightly tracked against light 13 pt subtitles. The secondary lines in the real window are small and grey ("34% left · On pace", `chrome-llm-usage-dark`). The large "11%" looks loosely spaced (`page-systemMonitor-*`). |
| 8 | Light and dark | medium | 7.5 | Both appearances look intended: tracks, tints and keycaps hold up in each (`*-light`/`*-dark` pairs). In dark mode the sidebar is near black against a dark grey content area, and the footer bands go darker than the panel. The real dark sheet has almost no edge (`chrome-models-info-dark`). |
| 9 | Empty, loading and error states | low | 7.0 | The system monitor loading popup is a proper skeleton with "Measuring…" (`popup-system-monitor-loading-*`). It is 3 pt taller than the loaded popup (1146 vs 1140 px), so the popup jumps when the data arrives. No other empty or error state is in the capture. |
| 10 | Iconography and brand | low | 7.5 | One style: SF Symbols in tinted tiles across the sidebar, menu and features (`page-features-*`, `menu-frog-*`). The frog brand is used with restraint. The stay-awake cup reads as a bowl and sits low in its tile. The command-bar footer repeats the magnifier from the search field (`command-bar-*`). |

## 2. Weighted overall

- High (×3): (6.5 + 6.0 + 7.0 + 4.0) × 3 = 23.5 × 3 = 70.5
- Medium (×2): (3.0 + 6.0 + 7.0 + 7.5) × 2 = 23.5 × 2 = 47.0
- Low (×1): 7.0 + 7.5 = 14.5
- Total 132.0 ÷ weights 22 (4×3 + 4×2 + 2×1) = **6.0**

## 3. Competitors (from the competitor set only)

Criteria that the set gives no evidence for are left out (–).

| Criterion (weight) | Raycast | iStat Menus | Ice | CodexBar |
|---|---|---|---|---|
| 1 Coherence (3) | 9.0 | 8.5 | 7.0 | 7.5 |
| 2 Alignment (3) | 9.0 | 8.5 | 7.5 | 8.0 |
| 3 Popups at a glance (3) | – | 8.5 | – | 8.0 |
| 4 Floating panels (3) | 8.5 | – | 7.0 | – |
| 5 Menu-bar items (2) | – | 9.0 | 8.5 | 7.0 |
| 6 Data usefulness (2) | – | 9.5 | – | 8.5 |
| 7 Typography (2) | 9.0 | 8.0 | 7.0 | 8.0 |
| 8 Light and dark (2) | – | 9.0 | – | 8.0 |
| 9 Empty states (1) | – | – | – | 6.0 |
| 10 Iconography (1) | 8.5 | 8.0 | 7.0 | 7.5 |
| **Overall** | **8.8** | **8.6** | **7.3** | **7.7** |

Arithmetic:
- Raycast: (9.0×3 + 9.0×3 + 8.5×3 + 9.0×2 + 8.5×1) = 106.0 ÷ 12 = 8.8. Launcher, Switch Windows and settings share one frame, radius and action bar (`raycast-launcher.jpg`, `raycast-switch-windows.jpg`, `raycast-settings.jpg`). The settings sidebar is inset concentric with the window. The older clipboard shot uses a different frame (`raycast-clipboard-history.jpg`). Only dark mode is shown.
- iStat Menus: (8.5×3 + 8.5×3 + 8.5×3 + 9.0×2 + 9.5×2 + 8.0×2 + 9.0×2 + 8.0×1) = 155.5 ÷ 18 = 8.6. The dropdowns share one card language across themes and both appearances (`istat-dropdown-themes.jpg`, `istat-dropdowns-light.jpg`). The menu-bar styles are crafted (`istat-menu-bar-items.jpg`). It leads on data: "298.8 GB available", processes, history. The pages are dense and use uppercase labels.
- Ice: (7.0×3 + 7.5×3 + 7.0×3 + 8.5×2 + 7.0×2 + 7.0×1) = 102.5 ÷ 14 = 7.3. The hidden sections are shown as real bars (`ice-menu-bar-layout-settings.jpg`, `ice-sections-and-general-settings.jpg`). The settings window is older-style, with a title bar and mixed surfaces. The icons are plain outline symbols.
- CodexBar: (7.5×3 + 8.0×3 + 8.0×3 + 7.0×2 + 8.5×2 + 8.0×2 + 8.0×2 + 6.0×1 + 7.5×1) = 147.0 ÷ 19 = 7.7. The usage popup is clear, with session and weekly bars, resets and pace, and cost today and over 30 days (`codexbar-popup.jpg`). It ends in a plain menu list. The empty state is one grey line (`codexbar-merged-menu.jpg`).

Frog at 6.0 is behind all four. The largest gaps are floating panels (4.0 vs Raycast 8.5), menu-bar items (3.0 vs iStat 9.0 and Ice 8.5) and data (6.0 vs iStat 9.5). Frog's popups (7.0) are close to CodexBar (8.0) and iStat (8.5); the misaligned LLM popup and the phone row are what hold them back.

## 4. Problems, most harmful to the core intent first

1. **The floating panels are not one family and only one of them moves.** The clipboard opens with its top at y 210 (upper third). The command bar and window switcher are centred near y 555. Widths are 680, 520 and 500 with no relation, and the switcher has no search field. Clipboard and switcher have no drag region: a real drag doesn't move them, and they reopen at their default place. The command bar remembers where it was put. Dark, real panels.
   Shots: `panels-placement.png`, `panels-movement.png`, `panels-movement.txt`, `panels-window-switcher.png`.
   Code: `native/FrogApp/Features/CommandBar.swift:299` (openingOrigin with `userPlaced`) and `:704-714` (centre); `native/FrogApp/Platform/ClipboardHistoryController.swift:161-165` (ClipboardHistoryLayout.origin); `native/FrogApp/Platform/WindowSwitcherController.swift:559, 688`; shared base `native/FrogApp/Platform/FrogFloatingPanel.swift`.
2. **A long phone name wraps in the Frog menu.** "OPPO Find X9 Pro / is offline" breaks into two grey lines next to the "Phone" title. This is the row height and hierarchy break the fixed item checks for. The status should read in one line, for example as a truncated name with an "Offline" badge. Light and dark.
   Shots: `menu-frog-light.png`, `menu-frog-dark.png`.
   Code: `native/FrogApp/Views/FrogStatusMenu.swift:152-161` (PhoneMenuRow passes the whole status as `key`), MenuActionRow `key`/`dot` around `:223`.
3. **The LLM usage popup's cards are off-centre.** The cards run from x 50 to 618 inside a panel that ends at 630: no left inset, 12 px on the right. The system monitor popup and the Frog menu sit at 56–624 (6/6). The card's left edge touches the panel edge. Light and dark.
   Shots: `popup-llm-usage-light.png`, `popup-llm-usage-dark.png` (compare `popup-system-monitor-light.png`).
   Code: `native/FrogApp/Views/UsageMenuView.swift:72-105` (UsageStatusPopover: content padding, header dropdown `.padding(.trailing, …)`, `.frame(width: Self.width)`); `UsageMenuCards` at `:30-39`.
4. **The system monitor shows storage used, not free space, and no 24-hour change.** "312 GB of 494 GB" with a used bar; the free amount is only in a tooltip. CPU, memory, storage and LLM cost show no change against yesterday. Popup and page, light and dark.
   Shots: `popup-system-monitor-*.png`, `menu-system-monitor-*.png`, `page-systemMonitor-*.png`, `chrome-system-monitor-dark.png`.
   Code: `native/FrogApp/Views/SystemMonitorView.swift:157-162` (storage `usage(... used:)`, free in `.help`).
5. **Menu-bar item styles and their pickers can't be seen, and the Hidden bar page has no picture of the bar.** The capture never shows a status item or a style picker; the system monitor page is cut at the "Menu bar" heading. The Hidden bar page is six toggles with no view of the hidden and visible sections, where Ice shows them as real bars.
   Shots: `page-systemMonitor-light.png` (bottom edge), `page-usage-*.png`, `page-menuBar-*.png`, `chrome-hidden-bar-dark.png`.
   Code: `native/FrogApp/Views/MenuBarDesignPicker.swift`, `native/FrogApp/Features/MenuBarMeter.swift`, `native/FrogApp/Views/HiddenBarPage.swift`.
6. **Meters of the same kind have two thicknesses.** The LLM limit bars measure 18 px (9 pt) in the popup. The system monitor CPU, GPU, memory, storage and battery meters measure 12 px (6 pt). The same mismatch shows on the pages. Light and dark.
   Shots: `popup-llm-usage-light.png` vs `popup-system-monitor-light.png`, `page-usage-light.png` vs `page-systemMonitor-light.png`.
   Code: `native/FrogApp/Views/Design/FrogChart.swift:126-131` (FrogMeter sizes); callers `native/FrogApp/Views/UsageDashboardView.swift:234`, `native/FrogApp/Views/UsageMenuView.swift:173, 333`, `native/FrogApp/Views/SystemMonitorView.swift:326`.
7. **The footer status and the time formats differ between surfaces.** Footers read "● Ready", "15m ago" with no icon (menu Usage tab), "clock 15m ago" (popup), "● Live" and "Measuring…". Relative times are "15m ago", "12 min ago" (clipboard), "Resets in 2 hr" and "10:40". The page's y axis reads "0" beside "$2.50" and "$5".
   Shots: `menu-frog-*`, `menu-llm-usage-*`, `popup-llm-usage-*`, `popup-system-monitor-*`, `clipboard-*`, `page-usage-light.png`.
   Code: `native/FrogApp/Views/RecentTimestamp.swift:14`; `native/FrogApp/Views/UsageMenuView.swift:236-290` (UsageMenuFooterStatus, UsageMenuStatus); `native/FrogApp/Views/PanelFooter.swift`; axis labels in `native/FrogApp/Views/UsageDashboardView.swift`.
8. **The second column of the system monitor page sits at three x positions.** GPU starts at x 1208, Storage at 1225 and Temperature at 1200 (2x), so the three cards don't share a column line. Light and dark.
   Shots: `page-systemMonitor-light.png`, `page-systemMonitor-dark.png`, `chrome-system-monitor-dark.png`.
   Code: `native/FrogApp/Views/SystemMonitorView.swift:113-125` (Memory and storage section) and the load and power sections' column layout.
9. **The real sidebar hides pages under the pinned Models, Features and Settings rows with no cue.** On the System monitor page the Mac group shows only "System monitor"; on Models it shows four entries. The selected row always lands just above the "Frog" header, and nothing shows that more rows sit below. Dark, real window.
   Shots: `chrome-system-monitor-dark.png`, `chrome-llm-usage-dark.png`, `chrome-stay-awake-dark.png`, `chrome-models-dark.png`.
   Code: `native/FrogApp/Views/MainView.swift:143-162` (bottom fade) and `:272-340` (scrolling list and pinned rows).
10. **The window corner and the sidebar inset aren't concentric.** The window corner is about 7 pt; the sidebar card inside it, inset 8 pt, has a corner of about 13 pt, so the two curves don't run parallel. The drawn pages show a much rounder sidebar than the real window.
    Shots: `chrome-system-monitor-dark.png` (top-left and bottom-left corners), compare `page-systemMonitor-light.png`.
    Code: `native/FrogApp/Views/DesignSystem.swift:66-73` (`sidebarRadius = max(windowRadius - sidebarInset, cardRadius)` clamps to the card radius), `native/FrogApp/Views/MainView.swift:337-340`.
11. **The real Models information sheet barely lifts off the page.** The sheet fill is almost the same as the dimmed content, with no hairline or shadow. The sheet's inner card is lighter than the sheet, so the result is three greys close together. The drawn sheet has a much larger corner than the real one. Dark.
    Shots: `chrome-models-info-dark.png` vs `sheet-local-model-info-dark.png`.
    Code: `native/FrogApp/Views/LocalModelInformation.swift`.
12. **The same API estimate is charted two ways.** It is a smooth line with no axis in the popup and the menu tab, and daily bars with an axis on the page. The popup line also starts inset from its date labels (x 93 vs 78).
    Shots: `popup-llm-usage-*`, `menu-llm-usage-*`, `page-usage-*`, `chrome-llm-usage-dark.png`.
    Code: `native/FrogApp/Views/UsageMenuView.swift:209` (UsageCompactActivity), `native/FrogApp/Views/Design/FrogChart.swift`.
13. **The Stay awake page has no state at a glance and shows a dependent switch on while the main switch is off.** "Keep the screen on" is on in the accent colour while "Keep this Mac awake" is off. Nothing on the page says the Mac is currently not being kept awake, beyond a small grey line.
    Shots: `page-stayAwake-dark.png`, `page-stayAwake-light.png`, `chrome-stay-awake-dark.png`.
    Code: `native/FrogApp/Views/StayAwakePage.swift`.
14. **The loading popup is 3 pt taller than the loaded one.** It measures 1146 px against 1140, so the popup changes height when the readings arrive.
    Shots: `popup-system-monitor-loading-*.png` vs `popup-system-monitor-*.png`.
    Code: `native/FrogApp/Views/SystemMonitorView.swift:180, 247, 254` (skeleton heights).
15. **The clipboard panel has no preview of the selected item.** Long entries are cut off, and the full text, image or link can't be checked before pasting. Raycast shows a preview pane (`raycast-clipboard-history.jpg`).
    Shots: `clipboard-*.png`, `panels-clipboard.png`.
    Code: `native/FrogApp/Views/ClipboardHistoryView.swift`.
