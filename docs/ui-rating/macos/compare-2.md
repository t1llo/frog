# Comparison 2: round 2 build (bb1632e) against the best so far (ec3ad74)

Two blind runs with fresh agents. Each saw only the criteria file and two folders, A and B.

**Key (added afterwards):** in run r8w, A = ec3ad74 (old) and B = bb1632e (new). In run t2v, A = bb1632e (new) and B = ec3ad74 (old).

## Verdicts, in terms of the new build

| # | Criterion | r8w | t2v | Agreed |
|---|---|---|---|---|
| 1 | Coherence of one system | new better | new better | **new better** |
| 2 | Alignment and spacing | new better (one regression) | new better (mixed) | **new better** |
| 3 | Menu-bar popups at a glance | new better | new better | **new better** |
| 4 | Floating panels as one family | new slightly better | new slightly better | **new better** |
| 5 | Menu-bar items and picker | new better | same (trade-off) | same |
| 6 | Data usefulness | new better | new better | **new better** |
| 7 | Typography and hierarchy | new better | new better | **new better** |
| 8 | Light and dark | same | same | same |
| 9 | Empty, loading, error | new slightly better | same | same |
| 10 | Iconography and brand | new better | new better | **new better** |
| | **Overall** | **new better** | **new better** | **new better** |

bb1632e becomes the best so far.

## Clearest differences

1. The Frog menu shows the full long phone name on a caption line, and every tab's footer reads "Settings ⌘ ,".
2. The Hidden bar preview reads as a real menu bar (Apple logo, items packed right, clock). The Steps and Columns menu-bar items are crisp and readable, and the picker grid is uniform.
3. The Stay awake page opens with a status card and titled sections, like the other pages. The storage bar fills to the share its label names. Clipboard rows show the source app and the time.

## What got worse (fix next)

- r8w: "Quit" lost its ⌘Q key caps while "Settings ⌘ ," keeps its own, so the one footer mixes two forms.
- Both runs: the LLM usage page chart lost its "$2.50" axis label, leaving an unlabelled middle grid line.
- r8w: inside the window switcher, the search placeholder no longer lines up with the row titles (148 vs 164).
- r8w: the picker previews lost the wallpaper band under the strip and now read as plain pills. t2v counted the band as a plus in the old build.
- r8w: the clipboard preview card ends at about 45% of the panel height, leaving an empty area under it.
- Both runs: the sidebar scroll edge now shows a half-faded, clipped row ("Focus timer", "App cleaner") next to the pinned "Frog" group. Neither build is clean there.

## Caveat on conditions

`popup-llm-usage-accounts-*` doesn't show the same sample state in the two builds. The round 2 improver changed that shot's provider from OpenAI to Claude, to match the "Max 20×" plans. Both runs noticed. That pair says less than the others.
