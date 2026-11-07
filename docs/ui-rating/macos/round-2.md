# UI rating macOS, round 2 judge report (capture bb1632e)

A fresh judge scored the screenshots in `docs/ui-rating/macos/shots/bb1632e/` against `docs/ui-rating/criteria.md`, and the competitors from `docs/ui-rating/competitors/`. File pointers to `native/FrogApp` only locate problems the pictures show; no score comes from code. (The judge returned its report as text; this file records it.)

**Overall: 7.9.**

## 1. Scores

| # | Criterion (weight) | Score | Reason |
|---|---|---|---|
| 1 | Coherence of one system (high) | 7.8 | Cards, footers, key caps and tiles are shared across `popup-*`, `menu-*` and `page-*`. Four things break it. The dark Models sheet has its own near-black, unedged surface (`chrome-models-info-dark`). The range controls are labelled three ways (`7d/30d`, `24h/7d/30d`, `7 days/30 days`). The Usage tab lays out its header differently from the standalone popup. The window switcher's row metrics differ from the other two panels. |
| 2 | Alignment and spacing precision (high) | 7.4 | Ghosted half-rows sit above the pinned "Frog" group and a ghost header shows under the search field (`chrome-*-dark`). The gap above "Frog" changes between pages. "No activity in this period" sits on the dashed baseline. Picker previews float small in wide capsules. The search caret overlaps the placeholder. |
| 3 | Menu-bar popups at a glance (high) | 8.3 | `popup-system-monitor-*` and `popup-llm-usage-*` answer in one look. The long phone name fits without truncation (`menu-frog-*`). Gaps: the CPU sparkline and the bar chart have no scale. |
| 4 | Floating panels as one family (high) | 8.0 | One anchor (620,266), one width (680), a shared frame and footer, and all three move and reopen where they were left (`panels-*`). Against that: two highlighted rows in the real command bar; every clipboard item says "Frog" in the real capture, with ~45% empty; switcher rows are 44 pt with text at 82 pt vs 40 pt and 72–74 pt. |
| 5 | Menu-bar items and how you choose them (medium) | 7.5 | `menubar-items-*` look crafted and the selected state is clear. The previews are small glyphs in oversized capsules, not items on a menu-bar strip. Sample values disagree across surfaces. "Columns" is barely readable. The hidden-bar glyphs are bare chevrons. |
| 6 | Data usefulness (medium) | 8.2 | Free storage with share and 24 h change, limits with reset and pace, token breakdowns, plan badge, source line. Missing: memory pressure, values or a scale on the popup charts. |
| 7 | Typography and hierarchy (medium) | 8.0 | One type scale, trailing values, clear roles. The footer action labels are heavier than needed. "Plan limits" in the popup vs "Limits" on the page. |
| 8 | Light and dark (medium) | 8.2 | Both appearances look intended. The dark Models sheet is the outlier (`chrome-models-info-dark`). |
| 9 | Empty, loading and error states (low) | 8.3 | Skeleton with "Measuring…", a designed "No activity" state with an icon; that text crowds the baseline. |
| 10 | Iconography and brand (low) | 8.2 | One tinted-tile SF Symbol style; the frog used with restraint; a finished cup. Exceptions: the raster mascot avatar in the sidebar and Settings, plain hidden-bar menu-bar glyphs. |

## 2. Weighted overall

High (7.8 + 7.4 + 8.3 + 8.0) × 3 = 94.5; medium (7.5 + 8.2 + 8.0 + 8.2) × 2 = 63.8; low 8.3 + 8.2 = 16.5. Total 174.8 / 22 = **7.9**.

## 3. Competitors (from the competitor set only)

| Competitor | Overall | Per criterion |
|---|---|---|
| Raycast | 9.1 | coherence 9.2, alignment 9.2, panels 8.8, typography 9.2, iconography 9.0 |
| iStat Menus | 8.9 | coherence 8.8, alignment 8.8, popups 9.0, menu-bar items 9.0, data 9.5, typography 8.5, light and dark 9.0, iconography 8.5 |
| Ice | 7.8 | coherence 7.5, alignment 8.0, panels 7.5, menu-bar items 8.5, typography 8.0, iconography 7.5 |
| CodexBar | 7.9 | coherence 7.8, alignment 8.0, popups 8.0, data 8.5, typography 8.2, light and dark 8.0, empty state 6.5, iconography 7.5 |

## 4. Problems, most harmful first

1. **Sidebar edges show cut, ghosted rows** at the real window size: a faded half-row on top of the pinned "Frog" header, a ghost "Write" header under the search field; the gap above "Frog" varies by page. Shots: `chrome-*-dark`, `page-hiddenBar-sections-*`, `page-systemMonitor-light`, `page-usage-dark`. Code: `Views/MainView.swift` ~150–170, 277–346, 415+; `Views/SidebarRowGrid.swift`.
2. **The command bar shows two highlighted rows** (selection "Proofread" and hover "Writing") in the real panel. Shots: `panels-command-bar` vs `command-bar-empty-dark`. Code: `Features/CommandBar.swift:1032`.
3. **The dark Models information sheet uses its own palette**: a near-black slab with no edge, darker than the cards. Shots: `chrome-models-info-dark` vs `sheet-local-model-info-*`. Code: `Views/LocalModelInformation.swift`, `Views/Design/FrogSurface.swift`.
4. **The clipboard panel looks thin and its sources look wrong**: every item from "Frog" in the real capture; ~45% empty; the preview repeats the title instead of showing the content large. Shots: `panels-clipboard`, `clipboard-*`. Code: `Views/ClipboardHistoryView.swift`.
5. **The three panels use different row metrics**: switcher 44 pt rows, text at 82 pt; others 40 pt, text at 72–74 pt. Code: `Views/WindowSwitcherOverlay.swift:13, 63, 73`.
6. **The time-range controls are inconsistent** (`7d/30d`, `24h/7d/30d`, `7 days/30 days`). Code: `Views/UsageDashboardView.swift:298–324`, `Views/Design/FrogDropdown.swift:130`.
7. **The menu-bar style pickers don't preview like a real menu bar**: tiny glyphs in ~160 pt capsules with no strip; numbers disagree with the rest of the app; "Columns" barely legible. Code: `Features/MenuBarMeter.swift`.
8. **The hidden-bar preview's captions don't map to sections**: they name states, aren't bracketed to their icons, and with icons shown there is no "Hidden" label. Code: `Views/HiddenBarPage.swift:54, 116–121`.
9. **The empty chart text sits on the dashed baseline** (`popup-llm-usage-accounts-*`). Code: `Views/UsageDashboardView.swift:362`.
10. **The disabled "Keep the screen on" switch is drawn on**: grey, knob right, reads as both on and unavailable (`chrome-stay-awake-dark`, `page-stayAwake-*`). Code: `Views/StayAwakePage.swift`.
11. **The Frog menu's tabs don't match the standalone popups**: the Usage tab's picker and buttons on a second header row; the Stay awake row's "No limit" pop-up stacked under its title (`menu-llm-usage-*`, `menu-frog-*`).
12. **The search caret overlaps the placeholder's first letter** (`panels-command-bar`, `panels-clipboard`).
