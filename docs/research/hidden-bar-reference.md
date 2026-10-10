# Hidden Bar reference and Frog organizer

Research date: 2026-10-10. Reference repository: **public, open-source, MIT-licensed**
[`dwarvesf/hidden`](https://github.com/dwarvesf/hidden). Pinned reference revision:
[`04d9f3f0df795e4facfa05efd2f96fceb46a0467`](https://github.com/dwarvesf/hidden/tree/04d9f3f0df795e4facfa05efd2f96fceb46a0467).
Frog's implementation is independently written; no Hidden Bar code or assets were copied.

## Primary-source behavior inventory

The upstream [README](https://github.com/dwarvesf/hidden/blob/04d9f3f0df795e4facfa05efd2f96fceb46a0467/README.md)
documents Command-drag arrangement and clicking the arrow to hide items.
The [manual](https://github.com/dwarvesf/hidden/blob/04d9f3f0df795e4facfa05efd2f96fceb46a0467/docs/MANUAL.md)
lists:

- Left-click arrow: reveal/collapse. Right-click arrow or click separator: menu
  containing Preferences, Toggle Auto Collapse, Quit.
- Icons left of the divider belong to the hidden section. Command-drag is the
  macOS arrangement gesture; the app does not reposition another app's icons.
- Auto-collapse interval, global shortcut, launch at login, show preferences at
  launch, optional always-hidden section, and “Use full menu bar on expanding.”
- Option-click changes separator/always-hidden visibility. Current legacy
  always-hidden behavior is coupled to hiding separators and has known limitations.
- Pointer-in-menu-bar defers auto-collapse. Removed helper icons recover on launch.
- Display changes resize the hiding spacer. Hover-to-expand is a Terminal-only
  option, with a roughly 0.5-second dwell. The auto-hide interval can also be
  configured beyond the UI's preset list. Language override uses AppleLanguages.

The upstream [architecture](https://github.com/dwarvesf/hidden/blob/04d9f3f0df795e4facfa05efd2f96fceb46a0467/docs/ARCHITECTURE.md)
describes public `NSStatusItem.length` inflation, a recovery arrow right of the
divider, a second optional divider, display-width sizing and a 10,000-point bound.
It explicitly documents notch occlusion, new status items appearing in the hidden
zone, and inability to know whether another app has a dropdown open when the
pointer is below the menu bar. The native macOS menu bar controls placement.

The pinned manual additionally describes a macOS 27 **direct-download-only native
engine**, Accessibility inventory, per-application visibility, exceptions for
macOS system icons, and an `/Applications` requirement. Architecture still describes
the factory as legacy-only, so those docs are not mutually consistent. The pinned
[source tree](https://github.com/dwarvesf/hidden/tree/04d9f3f0df795e4facfa05efd2f96fceb46a0467/hidden/Features/StatusBar/Engine)
includes a native visibility bridge/shim. Frog uses none of that bridge. It treats
macOS 27+ as unsupported for the public spacing mechanism and installs no helpers
there, rather than promising unsupported hiding or adding private APIs.

## Frog scope and differences

Implemented in `native/FrogApp/Platform/MenuBarOrganizer.swift`:

- Independent native arrow and trailing-edge divider markers; ordinary reveal,
  collapse, Command-drag arrangement, configurable 1–3,600-second auto-hide,
  opt-in Carbon shortcut, start-collapsed preference, optional hover reveal.
- Optional second divider: the section left of the double divider stays collapsed
  during ordinary reveal. “Reveal all & arrange” in Frog temporarily opens both
  sections and pauses auto-hide. No always-hidden/separator-visibility coupling.
- Re-check only Frog's helper frames, monitor width/notch regions, and restore
  compact lengths if the recovery arrow is obscured or the dividers are reversed.
  Display changes resize existing spacers. No foreign icon enumeration or moves.
- A single 0.5-second timer while installed; no global pointer monitor. Mouse-down,
  pointer in the menu strip, settings page visibility and arrangement editing defer
  auto-hide. Arbitrary third-party open dropdowns cannot reliably be detected.
- Stable autosave names `Frog.MenuBarOrganizer.toggle`, `.divider`,
  `.permanentDivider`. Keep autosave identity through helper removal, preserve macOS's
  stored positions, never touch private preferred-position defaults. Actual
  relaunch/disable/re-enable placement retention still needs live verification.
- No default shortcut. No Accessibility or Screen Recording permission. Teardown
  unregisters the shortcut, invalidates the timer and removes all owned items.
- If `com.dwarvesv.minimalbar` is running, do not install (or tear down already
  installed helpers). Display an explanation and Retry. Never terminate, uninstall
  or reconfigure Hidden Bar. Detection currently covers Hidden Bar, not every
  possible third-party menu-bar organizer.

Right-clicking Frog's arrow or clicking a divider opens a native context menu with
show/hide, show-all/arrange, checked auto-hide, and Menu bar settings. Option-click
opens/closes all-sections arrangement; ordinary clicking exits arrangement and hides
instead of silently ignoring the click. Auto-hide changes use the same persisted
preferences path as Settings. The existing Frog menu supplies Quit and the existing
app preferences supply login startup. Hidden Bar's Option-click separator hiding, show-preferences-at-launch,
and “full menu bar” activation-policy switching are not duplicated. Frog keeps its
existing quiet accessory lifecycle. These presentation differences should not be
described as exact feature parity. There is no second-row overflow panel, icon
pinning, or guaranteed access to icons physically occluded by a notch.

## Exact parent integration

The feature registry must default `.menuBar` **off**. Persist a
`MenuBarPreferences` child in portable toolkit preferences, with missing values
falling back to `MenuBarPreferences()`. Public fields:

```swift
autoHide: Bool                 // true
autoHideSeconds: Double        // 10; normalized to 1...3600
startCollapsed: Bool           // false
permanentlyHiddenSection: Bool // false
hoverToReveal: Bool            // false
hotkey: Hotkey?                // nil, opt-in
```

`normalized` provides the validated copy; the custom decoder also normalizes.
The parent should persist normalized values and validate any assigned shortcut
against its other enabled rules/tool shortcuts. Carbon also reports collisions.

Own one main-actor `MenuBarOrganizer` for the app lifetime:

```swift
let menuBarOrganizer = MenuBarOrganizer()
menuBarOrganizer.onShowSettings = { /* select .feature(.menuBar), show main window */ }
menuBarOrganizer.configure(enabled: preferences.featureEnabled(.menuBar),
                           settings: /* persisted MenuBarPreferences */)
// Alongside the parent's existing shortcut recorder suspension:
menuBarOrganizer.setShortcutRecording(recording)
// At shutdown (configure(enabled: false, settings: ...) also tears down):
menuBarOrganizer.stop()
```

Call configure on startup, preferences edits and configuration import. Do not create
a native organizer in unrelated test fixtures: its initializer supports injected
`OrganizerStatusItems`, `OrganizerHotkey`, clock, environment and disabled automatic
ticks. Native construction itself creates no status items until enabled.

Settings route:

```swift
MenuBarSettingsView(organizer: menuBarOrganizer,
                    settings: Binding(get: { /* current settings */ },
                                      set: { /* persist normalized value; configure */ }))
```

The view uses the existing `HotkeyRecorder` and thus needs the usual `AppModel`
environment object. It handles `setSettingsVisible` on appear/disappear. Exposed
observable state: `isEnabled` (requested), `isInstalled`, `isExpanded`,
`isEditingArrangement`, `issue`, `hotkeyError`. Actions: `toggle()`, `reveal()`,
`setEditingArrangement(_:)`; the latter is the all-sections window recovery path.
Keep the main window reopen action reachable through launching Frog in Applications.

## Verification and remaining manual checks

### Organizer refinement

The isolated regression loop `.scratch/debug/check-menu-organizer.py` reproduced
three bugs (five failed assertions): geometry repair resized spacers mid-Command-drag;
missing menu windows during a transition discarded collapsed intent; a preference
change could inflate an unvalidated permanent divider. The fixes defer repairs until
mouse-up, preserve state while frames are unavailable, and validate before applying
permanent collapse. Native context-menu tests exercise actual NSMenu actions without
installing status items, including persistence callbacks and paused auto-hide tracking.
The arrow uses a compact template chevron and Settings uses a visual divider diagram.
These are synthetic regressions, not evidence that every live display configuration
or the user's unspecified symptoms have been reproduced.

### Native layout and removal follow-up

Real status-item probes on macOS 26 subsequently reproduced the reported flicker:
`NSStatusItem.length` updates the window width immediately while WindowServer still
reports its old origin. An intervening geometry tick mistook that rectangle for a
divider moved to the wrong side and reopened the section. Width changes now get a
bounded one-second layout grace before invalid-order recovery. A continuously unsafe
arrangement still recovers after that grace. Both timer and settings paths obey it.

The same native probe found empty-slot accumulation: clearing `autosaveName` before
`removeStatusItem` orphaned the old remote menu slot. Three removed fixture items
left three slots; retaining the two organizer identities reduced that to one, and
retaining the fixture neighbor's identity too returned the slot count to baseline.
Frog now preserves the identity throughout removal and restores visibility on install.
No private preferred-position defaults or other apps' icons are modified by this fix.

Deterministic tests model the width/origin transition and bounded recovery. The
archived native geometry probe additionally checks actual hide/reveal, stable spacing
and remote slot cleanup. Native probes record only geometry, never menu screenshots
or another app's content. Existing orphaned macOS slots can require a menu-bar service
refresh once; Frog does not restart system services automatically.

The isolated package at the approved temporary `frog-menu-organizer-verification`
directory compiles copies of real FrogCore, MenuBarOrganizer and HotkeyManager,
without touching the shared `.build` or creating native status items. Nine
app tests and two core tests passed (11 tests, zero failures).
They cover reversed geometry/recovery, notch bounds, monitor sizing, permanent
section/edit behavior, lifecycle idempotence/late ticks, auto-hide interaction
deferral, shortcut conflict/suspension, hover dwell, unsupported OS/Hidden Bar
coexistence, and migration/normalization/portable round-trip.
The divider test uses real AppKit button autoresizing at 18/5,000/10,000 points
to verify its marker stays at the visible trailing edge without intercepting
clicks. The settings view also compiled with the real design system, compact
controls and shortcut recorder in an isolated app-shell fixture.

Parent must run the final integrated build/tests. Manual verification requires a
session where the user has quit Hidden Bar themselves:

1. Enable the feature, verify one arrow and one divider with a visible trailing
   marker at both ordinary and inflated widths; Command-drag unrelated fixture
   icons on either side. Confirm the arrow never collapses behind its divider.
2. Collapse/reveal via arrow and a user-selected unused hotkey. Test conflict
   reporting and suspending the shortcut while recording another shortcut.
3. Confirm auto-hide delay, pointer/drag deferral, settings-page pause and hover.
4. Enable the double divider; arrange left-to-right as described by the UI. Ordinary
   reveal must keep the leftmost section hidden; settings recovery reveals both.
5. Disable/re-enable, quit/relaunch, change displays, test a notched screen and
   fullscreen Spaces. Check macOS position retention and recovery notices.
6. Disable/quit: all helpers disappear and their hotkey no longer acts. Launching
   the app from Applications must reopen the window for recovery.

No user menu arrangement, installed Hidden Bar process or actual provider settings
were changed during the isolated tests. Real icon arrangement is not yet verified.
