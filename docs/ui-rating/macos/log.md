# Run log (macOS)

Base branch `ui-rating-2`, platform branch `claude/ui-rating-macos-b98e6c`. Target 9/10, cap 2 improve rounds.

## Setup

- Fixed clock: `FROG_FIXED_NOW` (debug and test builds only), 2026-11-07 13:40 local; UIShotsTests pins it for its run (59d7107, 92db0ba).
- Sample paired phone "OPPO Find X9 Pro", offline, in the UIShots sample data (92db0ba).
- Debug-instance capture (window chrome at 980×680, real panel placement, emulated movement) from a temporary hook that is never committed. Synthetic mouse events aren't permitted for this process, so movement is emulated through each panel's own end-of-drag code where it has one; `panels-movement.txt` says how.
- Repeatability: two UIShots runs of the same build matched on 144 of 150 pictures; the 6 that differ are small animated areas (a streaming spinner, the cleaner's spinner, a glow on the coding-tools rows, the selection bubble's animation) on surfaces outside the fixed items. Two debug-instance runs matched on 10 of 11 pictures; `chrome-system-monitor-dark` differs in 839 scattered pixels of the live chart area.
- Committed capture per build: the fixed-item surfaces (light and dark) plus the debug-instance shots, about 11 MB.

## Rounds

| Round | Commit | Overall | Criteria 1-10 | Raycast | iStat | Ice | CodexBar | Comparison vs best | Ledger (open/reopened/closed) | Decision | Best so far |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 92db0ba | 6.0 | 6.5, 6.0, 7.0, 4.0, 3.0*, 6.0, 7.0, 7.5, 7.0, 7.5 | 8.8 | 8.6 | 7.3 | 7.7 | (first judge) | 20 open / 0 / 0 | below target → improve round 1 (owner items first) | 92db0ba |
| 1 | ec3ad74 | 7.7 | 7.8, 7.4, 7.3, 8.5, 7.2, 8.0, 7.9, 7.8, 7.5, 7.8 | 9.0 | 8.1 | 7.2 | 7.2 | new better (both runs; vs e2f1bec) | 8 open / 9 reopened / 12 closed | below target, cap allows → improve round 2 | ec3ad74 |
| 2 | bb1632e | 7.9 | 7.8, 7.4, 8.3, 8.0, 7.5, 8.2, 8.0, 8.2, 8.3, 8.2 | 9.1 | 8.9 | 7.8 | 7.9 | new better (both runs; vs ec3ad74) | 5 open / 10 reopened / 18 closed (1 fixed, unconfirmed) | cap of 2 improve rounds reached → stop; target 9 not reached | bb1632e |

\* Criterion 5 was scored without any shot of the pickers or menu-bar items (capture gap); the capture adds them from round 1 and the baseline is recaptured with them for the comparison.

Round 1: the comparison ran against e2f1bec, the baseline recaptured with the pickers (same app code as 92db0ba). No merge from the base branch in this round.

Round 2:
- The menu-bar work ran on a separate branch, `ui-r2-menubar`, merged at c610016 before the capture. There was no merge from the base branch.
- Conditions: the round 2 improver changed the sample provider of `popup-llm-usage-accounts-*` from OpenAI to Claude, to match the "Max 20×" plans. Both comparison runs noticed, so that pair says less than the others.
- The real command bar's second highlighted row (J18) comes from the pointer resting over the panel during the capture. The hover fill is real, but whether a pointer sits there is a capture choice.
- Not seen in stills: O14 (tab switch motion) was checked by the improver with frame sequences from a debug instance; no judge can see it in the capture.
- Stop rule: the cap is reached. O11, O13/J4, J6 and J8 have now been reopened twice. Without the cap, the plateau rule would call for a design pass on the main window's sidebar and the menu-bar style previews.
- Judge noise: across rounds 0-2 the competitor scores spread by 0.3 (Raycast 8.8-9.1), 0.8 (iStat 8.1-8.9), 0.6 (Ice 7.2-7.8) and 0.7 (CodexBar 7.2-7.9).
