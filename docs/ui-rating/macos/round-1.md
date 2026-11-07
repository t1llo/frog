# UI rating macOS, round 1 judge report (capture ec3ad74)

Judged from the screenshots in `docs/ui-rating/macos/shots/ec3ad74/` against `docs/ui-rating/criteria.md`. The competitors were judged from `docs/ui-rating/competitors/` only. File pointers to `native/FrogApp` locate problems that the pictures show. None of the scores come from the code.

## 1. Scores

| # | Criterion | Weight | Score | Reason |
|---|---|---|---|---|
| 1 | Coherence of one system | high | 7.8 | Cards, accent, footers and key caps match across the menu, popups and panels (`menu-*`, `popup-*`, `clipboard-*`, `command-bar-*`). The sidebar edge shades show as blurred grey smudges (`chrome-*-dark`, `page-*`). The Stay awake and Hidden bar pages drop the section headers that every other page has (`chrome-stay-awake-dark`, `chrome-hidden-bar-dark`). |
| 2 | Alignment and spacing precision | high | 7.4 | Card insets and tiles are mostly exact. The window switcher's search line sits about 8 pt further right than the command bar's and the clipboard's (`window-switcher-light`, `panels-window-switcher`). The "Renewed" row breaks the % column (`popup-llm-usage-accounts-*`). The picker grid uses 4 columns, then 3 (`picker-*`). The Hidden bar preview spreads its items across wide gaps (`page-hiddenBar-sections-*`). |
| 3 | Menu-bar popups at a glance | high | 7.3 | The hierarchy is clear and the bars, pace markers and chart are readable (`popup-llm-usage-*`, `popup-system-monitor-*`). But the fixed long-name phone is truncated to "OPPO Find X9…" (`menu-frog-*`). The storage bar shows the used share while its label gives the free share (`popup-system-monitor-*`). The Usage tab footer loses its "Settings" label (`menu-llm-usage-*`). |
| 4 | Floating panels as one family | high | 8.5 | All three panels share one anchor (620,266), one 680 pt width, one frame and one footer. They move and reopen where they were left (`panels-placement`, `panels-movement`, `panels-movement.txt`). Gaps: the switcher's search inset differs, and the clipboard preview is mostly empty space (`clipboard-*`). |
| 5 | Menu-bar item designs and picker | medium | 7.2 | The previews sit on a real bar strip and the selected one has a clear ring (`picker-*`). The Columns style labels are about 5 pt and can't be read. Partly filled Spectrum and Traffic-light steps look muddy in dark and washed out in light (`menubar-items-*`). The picker grid doesn't line up. |
| 6 | Data usefulness | medium | 8.0 | The status pages show free storage with its share, the change since yesterday, pace against the limit, reset times and spend per day (`page-systemMonitor-*`, `page-usage-*`). Weak spots: the storage bar semantics, and a Stay awake page whose only status is a tiny "Sleeps as usual" (`page-stayAwake-*`). |
| 7 | Typography and hierarchy | medium | 7.9 | One type scale, with values on the trailing edge everywhere (`chrome-*`, `sheet-local-model-info-*`). Small lapses: the y-axis labels mix "$5" and "$2.50" (`page-usage-*`), the "Shown" label floats alone (`page-hiddenBar-sections-*`), and the accounts are named "A" and "B". |
| 8 | Light and dark | medium | 7.8 | Both appearances look intended and the materials hold up (`*-light`/`*-dark` pairs). In dark, the sidebar shade reads as a light haze and an on-but-disabled toggle reads as broken (`page-stayAwake-dark`). In light, the Spectrum steps fade to beige (`menubar-items-light`). |
| 9 | Empty, loading and error states | low | 7.5 | The system monitor has a designed skeleton with a "Measuring…" status (`popup-system-monitor-loading-*`). LLM usage has a calm note that account activity is unavailable (`page-usage-*`). The capture shows few other states. |
| 10 | Iconography and brand | low | 7.8 | SF Symbols in tinted tiles, used consistently. The stay-awake cup is clean and the frog is used sparingly (`menu-frog-*`, `chrome-*`). The Hidden bar tile is a plain grey window glyph (`chrome-hidden-bar-dark`). The Qwen model tiles use a different illustration style (`page-models-local-*`). |

## 2. Weighted overall

- High (×3): 7.8 + 7.4 + 7.3 + 8.5 = 31.0 → 93.0
- Medium (×2): 7.2 + 8.0 + 7.9 + 7.8 = 30.9 → 61.8
- Low (×1): 7.5 + 7.8 = 15.3 → 15.3
- Total 170.1 / 22 = 7.73 → **7.7**

## 3. Competitors (from the competitor set only)

| Criterion (weight) | Raycast | iStat Menus | Ice | CodexBar |
|---|---|---|---|---|
| 1 Coherence (3) | 9.0 | 8.5 | 7.0 | 7.5 |
| 2 Alignment (3) | 9.0 | 8.5 | 7.5 | 7.5 |
| 3 Popups at a glance (3) | – | 8.5 | – | 8.0 |
| 4 Panels family (3) | 9.0 | – | – | – |
| 5 Menu-bar items and picker (2) | – | 9.0 | 7.5 | 7.0 |
| 6 Data usefulness (2) | – | 9.0 | – | 8.0 |
| 7 Typography (2) | 9.0 | 8.0 | 7.0 | 7.5 |
| 8 Light and dark (2) | – | 8.5 | – | 7.5 |
| 10 Iconography (1) | 8.5 | 8.0 | 7.0 | 7.5 |
| **Overall** | **9.0** (107.5/12) | **8.1** (153.5/19) | **7.2** (79.5/11) | **7.2** (136.5/19) |

- **Raycast** (`raycast-*`): the launcher, clipboard and window switcher share one frame, one search line and one action bar. That is the reference for Frog's panel family. Movement isn't shown, so panels get 9, not higher.
- **iStat Menus** (`istat-*`): dense and polished dropdowns, and the richest menu-bar item set (graphs, bars, stacked labels) in both appearances. It is a little busy at a glance.
- **Ice** (`ice-*`): the sections lay out like a real menu bar, with items packed to the right. The tinted sidebar and saturated blue bars feel less native.
- **CodexBar** (`codexbar-*`): a clear popup with pace and reset times, but it is a long native menu with a mix of tinted and plain settings icons.

Frog (7.7) is ahead of Ice and CodexBar, close to iStat on data, and behind Raycast on precision and finish.

## 4. Problems, most harmful to the core intent first

1. **Long phone name truncated in the Frog menu.** The fixed item reads "OPPO Find X9… · Offline". The name is cut while the row has room to wrap or to drop the "Phone" label. Light and dark. Shots: `menu-frog-light.png`, `menu-frog-dark.png`. Code: phone row in `Views/FrogStatusMenu.swift`.
2. **Storage bar contradicts its label.** The text says "182 GB free · 37% of 494 GB" while the bar fills to 63% (the used share). At a glance it reads as 63% free. Popup, menu, page and window, both appearances. Shots: `popup-system-monitor-*`, `menu-system-monitor-*`, `page-systemMonitor-*`, `chrome-system-monitor-dark.png`. Code: `Views/SystemMonitorView.swift:170-176` (label uses `freeFraction`, meter uses `usedFraction`).
3. **The Usage tab footer drops "Settings".** It shows a bare "⌘ ," next to "Quit ⌘Q", while the Frog and System tabs show "Settings ⌘ ,". The longer "15 min ago" status makes the footer fall back to its compact form. Shots: `menu-llm-usage-dark.png`, `menu-llm-usage-light.png` vs `menu-frog-*`, `menu-system-monitor-*`. Code: `Views/PanelFooter.swift` (`ViewThatFits` around line 83), `Views/FrogStatusMenu.swift:115`.
4. **Sidebar edge shades look like smudges.** The soft shade above the pinned "Frog" rows, and the one under the search field, render as blurred grey bands: a dirty streak in light, a light haze in dark. They don't read as a scroll edge. Shots: `chrome-stay-awake-dark.png`, `chrome-hidden-bar-dark.png`, `chrome-models-dark.png`, `page-systemMonitor-light.png`, `page-hiddenBar-sections-light.png`. Code: `Views/MainView.swift:174-180`.
5. **The accounts popup is hard to read.** Account B's "Session" row has an empty bar, no %, and "Renewed" pushed into the reset column, which breaks the column rhythm. The accounts are named "A" and "B", and the plan chips say "Max 20×" under the provider "OpenAI". Light and dark. Shots: `popup-llm-usage-accounts-light.png`, `popup-llm-usage-accounts-dark.png`. Code: `Views/UsageMenuView.swift` ("Renewed").
6. **The window switcher's search line is out of step with its family.** Its magnifier and placeholder sit about 3 and 8 pt (2x: 110/164 px) further right than on the command bar (105/148) and the clipboard (104/144). This is visible when the panels are stacked. Shots: `window-switcher-light.png`, `command-bar-query-light.png`, `clipboard-dark.png`, `panels-window-switcher.png`, `panels-command-bar.png`. Code: `Views/WindowSwitcherOverlay.swift:110-116` (`searchLine`).
7. **The Hidden bar preview doesn't look like a menu bar.** "…" and "‖" sit far left, three icons in the middle, a lone divider, then the visible items, all with wide empty gaps. Real bars and Ice pack items to the right. The "Shown" status floats alone at the bottom right. Shots: `page-hiddenBar-sections-light.png`, `page-hiddenBar-sections-dark.png` vs `ice-menu-bar-layout-settings.jpg`. Code: `Views/HiddenBarPage.swift:56-70` (`HiddenBarArrangement`, `Spacer`s).
8. **The menu-bar style pickers aren't a tidy grid.** The Style row has 4 tiles and the Colors row has 3 wider tiles, so the edges don't line up. Every preview carries a lavender or blue band under the strip that reads as a stray fill. Shots: `picker-llm-usage-menubar-*`, `picker-system-monitor-menubar-*`. Code: `Views/MenuBarDesignPicker.swift`.
9. **The Columns style can't be read at menu-bar size.** The "5h/7d" and "CPU/GPU" captions under the pills are about 5 pt and the pills are tiny next to the other styles. Shots: `menubar-items-*`, `picker-*`. Code: `Features/MenuBarMeter.swift`.
10. **Partly filled Spectrum and Traffic-light steps look muddy.** Reduced alpha turns the steps olive and brown in dark and beige and salmon in light, so the item looks dirty rather than graded. Shots: `menubar-items-dark.png`, `menubar-items-light.png`, `picker-system-monitor-menubar-dark.png`. Code: `Features/MenuBarMeter.swift:100-115` (`Ink.fill` with `strength`).
11. **On-but-disabled toggle on Stay awake.** "Keep the screen on" is a dim purple track with a grey knob while the main switch is off, and it reads as broken. Dark. Shots: `page-stayAwake-dark.png`, `chrome-stay-awake-dark.png`.
12. **Stay awake and Hidden bar pages are inconsistent with the rest of the window.** In the real window they drop the section headers that System monitor, LLM usage and Models use. Stay awake's state is only a small "○ Sleeps as usual" in the corner, with no glanceable status card. Shots: `chrome-stay-awake-dark.png`, `chrome-hidden-bar-dark.png` vs `chrome-system-monitor-dark.png`.
13. **LLM chart axis labels use mixed formats.** "$5", "$2.50" and "$0" mix whole and two-decimal values. Shots: `page-usage-light.png`, `chrome-llm-usage-dark.png`.
14. **The clipboard preview is mostly empty.** A one-line clip leaves about 70% of the preview pane blank, and the rows carry no source app or time, unlike Raycast. Shots: `clipboard-dark.png`, `panels-clipboard.png` vs `raycast-clipboard-history.jpg`. Code: `Views/ClipboardHistoryView.swift`.
15. **The Hidden bar sidebar icon is weaker than the rest.** It is a plain grey window glyph next to tinted, meaningful tiles. Shot: `chrome-hidden-bar-dark.png`.
