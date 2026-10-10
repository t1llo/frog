# Native reliability comparison

Inspected the local Vorssaint checkout at
[`47c2653c3ced7b0118ff88b653ebb2425c690021`](https://github.com/vorssaint/vorssaint-utils/tree/47c2653c3ced7b0118ff88b653ebb2425c690021),
the same revision as the [usage research](vorssaint-usage-reference.md).
The reference implementation is GPL-licensed. These findings describe behavior and
test cases; its implementation and assets have not been imported into Frog.

## Clipboard selection

Frog's history observer preserved an array index while new observations inserted at
the front. The actual observer, exercised with synthetic entries, changed selection
from B to A after insertion and from B to C after deletion above B. The corrected
observer resolves the previous selected identity before reconciling the new list;
both cases retain B. A native keyboard-delivery regression also covers this path.

Reference: `Sources/Vorssaint/Services/Clipboard/ClipboardHistoryService.swift`
(selected-entry identity) and `Tests/ClipboardFeatureTests.swift` (selection across
insertion/deletion). Frog: `ClipboardHistoryController.swift` and
`ClipboardHistoryTests.swift`. No clipboard contents from a real session were used.

## Window discovery and activation

The comparison identified two distinct contracts:

- An unanswered Accessibility request is unknown, rather than proof that every
  window in the application closed. Preserve bounded last-known identity through
  transient failures, but remove entries after a successful empty inventory.
- A successful AX raise does not prove foreground ownership. Command search should
  use the same guarded activation routine as the window switcher, including unhide,
  foreground verification and a final exact-window raise.

Reference: `Services/Switcher/WindowEnumerator.swift`, `WindowActivator.swift`,
`Services/CommandBar/CommandBarCatalog.swift` and
`Tests/SwitcherAccessibilitySnapshotTests.swift`. Frog's corresponding seams are
`WindowCatalog`, `WindowSwitcherCache`, `WindowActivation` and `CommandBar`.
The source paths establish failure possibilities; they do not establish their
frequency on a particular desktop or verify permission-gated interactions.

## Session and menu geometry

Input-event ownership needs session/wake reconciliation: deactivate GUI input taps
for an inactive login session, prevent late rearming and check tap health on wake.
This is separate from background jobs and Stay awake, which must not implicitly
pause merely because the screen locks. Reference: `Services/SessionActivity.swift`,
`Services/Switcher/AppSwitcher.swift`, and `Tests/PointerInputFeatureTests.swift`.

Long errors should have bounded previews in Frog's menu, with full details retained
in Logs. Reference `UI/MenuPanel/MenuPanelView.swift` budgets height using the anchored
display and tests recovery in `Tests/MenuPanelRecoveryTests.swift`. Unbounded error
content is a concrete sizing risk; it does not prove the cause of the previously
reported intermittent oversized popup.

## Follow-up: lifecycle and presentation ownership

The README's feature-lifecycle contract and `CONTRIBUTING.md` reinforce keeping
reusable decisions outside views and verifying native behavior separately from a
successful build. The follow-up reread of `App/FeatureRuntime.swift`,
`Services/CommandBar/CommandBarSelection.swift`, and `UI/MenuPanel/MenuPanelView.swift`
focused on enable/disable ownership, transient work and anchor-display sizing.

Concrete Frog follow-up changes:

- Usage's popup creates its hosted content only on opening and budgets height using
  the display containing its own status item. Detailed history stays in the dashboard;
  the popup's summary is independently bounded, without changing collection cadence.
- Organizer geometry distinguishes the requested collapsed state from an in-flight
  WindowServer layout. Native slot ownership must survive until removal completes;
  clearing autosave identity early caused orphaned slots. These native findings are
  documented in the [organizer reference](hidden-bar-reference.md).
- Popup clipping must include the native content host, not just the SwiftUI subtree.
  A synthetic `MenuBarExtra` reproduced opaque square-corner pixels behind the rounded
  content. The shared material now applies the same corner outline to its blur mask
  and the borderless native host. Titled app windows keep their native frame.

These are independent implementations of lifecycle and geometry contracts. The
reference's design, private integrations and unrelated features were not imported.

## Build and test lessons

Keep Frog's three SwiftPM test targets and signed local-checkout build. The reference
uses a standalone generated fixture runner (`build.sh`, `Tests/generate_sources.py`),
whereas Frog can directly exercise its modules with `@testable` imports. Both benefit
from native-boundary fixtures plus bundled walkthroughs. Reference mutation checks
(`Tests/mutation_checks.py`) distinguish intended assertion failures from compilation
errors and timeouts; the same distinction applies to these regressions.

The shared publishing script builds the pushed default branch and is not a substitute
for the authorized, uncommitted local app build. No publishing or reference app build
was performed for this comparison.
