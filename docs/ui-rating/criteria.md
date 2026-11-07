# UI rating run 2 (2026-11-07): criteria, items and frozen conditions

Fixed for the whole run. Every judge and comparison uses this list unchanged.

- **Platform:** the native macOS app (main window, menu-bar menu and popups, floating panels).
- **Target:** 9/10 (average of two judges on the same capture).
- **Round cap:** 2 improve rounds.
- **Competitors:** Raycast (launcher, clipboard, window management, settings window), iStat Menus (system monitor popups and menu-bar styles), Ice (hidden menu-bar items), CodexBar (LLM usage in the menu bar).

## Core user intent

Frog lives in the menu bar. People open it to reach a tool at once (command bar, clipboard, windows) or to read a status at a glance (CPU, storage, LLM limits, stay awake). Every surface should feel like one calm, native Mac app: the same geometry, colours, spacing and controls everywhere, and nothing that looks unfinished.

## Criteria

| # | Criterion | Weight | What a 10 looks like | Evidence |
|---|---|---|---|---|
| 1 | Coherence of one system | high | Every page, popup, sheet and panel uses the same surface colours, radii, insets, row heights and controls; a sheet or popup never brings its own palette. Window corner radius and sidebar inset radius are concentric; sidebar and content backgrounds read as one window. | window shots, sheets, popups side by side |
| 2 | Alignment and spacing precision | high | Icons centred in their tiles and buttons (optically, both axes); equal left and right insets in cards; consistent gaps between cards; bars and tracks of one thickness per kind. | close crops of tiles, cards, bars, footers |
| 3 | Menu-bar popups at a glance | high | The Frog menu, LLM usage and system monitor popups answer their question in one look, with clear hierarchy, readable charts and bars, and no truncation or odd wrapping (long device names included). | popup shots, long-name state |
| 4 | Floating panels as one family | high | Command bar, clipboard history and window switcher share one placement and sizing concept (same anchor, related widths), a shared frame and footer, and can be moved like in Raycast, remembering where they were put. | panel shots on the same screen, movement clip |
| 5 | Menu-bar item designs and how you choose them | medium | The status-item styles (LLM usage, system monitor, hidden bar) look crafted at menu-bar size, and the picker shows them as real menu-bar previews with a clear selected state, laid out in a tidy grid. | menu-bar style pickers, menu-bar crops |
| 6 | Data usefulness | medium | Status pages show what people want next: free storage and its share, change against 24 hours ago, limits with reset times; numbers formatted consistently. | System monitor page and popup, LLM usage page and popup |
| 7 | Typography and hierarchy | medium | One type scale, clear title/subtitle/value roles, values aligned to the trailing edge, no cramped or orphaned labels. | all shots |
| 8 | Light and dark | medium | Both appearances look intended: contrast, materials and accent tints work in each. | light and dark pairs |
| 9 | Empty, loading and error states | low | Every state has a designed placeholder, never a blank or raw error. | loading and empty shots |
| 10 | Iconography and brand | low | One icon style (SF Symbols in tinted tiles), crisp at size, the frog brand used with restraint; the stay-awake icon and others look finished. | sidebar, menu, tiles |

Overall score: weighted mean (high 3, medium 2, low 1), one decimal.

## Fixed items (judged every round)

1. Frog menu-bar menu, with a paired phone whose name is long ("OPPO Find X9 Pro") and offline.
2. Main window: chrome (corner, sidebar, content background) on the System monitor, LLM usage, Stay awake, Hidden bar and Models pages, including the Models information sheet.
3. Menu-bar popups: LLM usage and system monitor.
4. Floating panels: command bar, clipboard history, window switcher.
5. Menu-bar style pickers on the LLM usage and system monitor pages, and the hidden bar.

## Frozen capture conditions

- **Capture:** `scripts/ui-shots.sh <folder>` (UIShotsTests) draws every surface in light and dark from isolated sample data; it never touches the real Frog data. Window chrome, real panel placement and movement are captured from an isolated debug instance (`FROG_DATA_DIRECTORY` pointing at the sample data, never `/Applications/Frog.app`) with the same window size every round (980×680).
- **Clock:** a fixed time, 2026-11-07 13:40 local, daylight. Any "ago", reset time, chart range or "until" in the shots comes from this fixed clock, never from the real one (debug and test builds only).
- **Data:** the sample data in UIShotsTests and SampleSystemSampler; no live usage, CPU or network values.
- **Names:** `shots/<commit>/<surface>-<light|dark>.png` as written by the script, plus `chrome-<page>-dark.png` and `panels-*.png` for the debug-instance shots, the same names every build.
- **Motion:** one short clip per round of dragging the command bar, clipboard and window switcher and reopening them.
- **Check:** two captures of the same build must look the same.
- **Competitors:** one set of public screenshots (product pages, docs, press kits; never signed in, cookies declined) saved once in `docs/ui-rating/competitors/` and reused by every judge.
