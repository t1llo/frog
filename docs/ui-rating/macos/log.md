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

\* Criterion 5 was scored without any shot of the pickers or menu-bar items (capture gap); the capture adds them from round 1 and the baseline is recaptured with them for the comparison.
