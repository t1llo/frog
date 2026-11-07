# Comparison 1: round 1 build (ec3ad74) against the best so far (e2f1bec, the baseline 92db0ba recaptured with the pickers)

Two blind runs with fresh agents. Each saw only the criteria file and two folders, A and B.

**Key (added afterwards):** in run p7k, A = e2f1bec (old) and B = ec3ad74 (new). In run q3m, A = ec3ad74 (new) and B = e2f1bec (old).

## Verdicts, in terms of the new build

| # | Criterion | p7k | q3m | Agreed |
|---|---|---|---|---|
| 1 | Coherence of one system | new better | new better | **new better** |
| 2 | Alignment and spacing | new better | new better | **new better** |
| 3 | Menu-bar popups at a glance | new better (two regressions) | old slightly better | same |
| 4 | Floating panels as one family | new better, clearly | new better, decisive | **new better** |
| 5 | Menu-bar items and picker | new better | new slightly better | **new better** |
| 6 | Data usefulness | new better | new better | **new better** |
| 7 | Typography and hierarchy | same | new slightly better | same |
| 8 | Light and dark | new better | same | same |
| 9 | Empty, loading, error | new slightly better | new slightly better | **new better** |
| 10 | Iconography and brand | same | same | same |
| | **Overall** | **new better** | **new better** | **new better** |

ec3ad74 becomes the best so far.

## Clearest differences (both runs)

1. The floating panels are one family: one anchor, one 680 pt width, a shared search header and footer, and all three reopen where they were moved. Before, there were three sizes at three places, and two panels forgot where they had been put.
2. The system monitor shows free storage with its share and the 24-hour change, and its second column lines up across cards.
3. The LLM usage popup matches the page: the same chart, the same 7d/30d control, the same card inset and time format.

## What got worse (found by both runs unless noted)

- The Usage tab footer in the Frog menu (`menu-llm-usage-*`) shows bare ⌘ , keycaps with no "Settings" label.
- The long phone name is cut to "OPPO Find X9…" (`menu-frog-*`). Before, it wrapped onto two lines.
- The sidebar's scroll-edge shade above the pinned "Frog" group reads as a smudge over empty space.
- p7k only: the clipboard panel lost its row timestamps; long items truncate in the narrower list; the preview pane is mostly empty for short text.
- p7k only: the storage bar fills to the used share while the headline number is the free amount.
- p7k only: the window switcher's search glyph sits about 4 pt further in than in the other two panels.
- q3m only: the models sheet's corner radius is not concentric with its inner card.
- q3m only: the picker's Colors tiles are wider than its Style tiles.
