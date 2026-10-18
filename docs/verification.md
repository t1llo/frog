# Native verification

## Clipboard delivery and switcher follow-up

The cross-Space native reproduction confirmed that AX omitted a window on another
Desktop while WindowServer still contained it. `WindowSpaceBridge` augments the
inventory with validated owner/window IDs, selects the existing destination Space,
then resolves and activates the exact AX window. It dynamically resolves optional
private macOS Space APIs; missing symbols retain the ordinary AX path. No Screen
Recording, preference changes or window relocation are required. Window titles
unavailable from macOS use cached AX text or a neutral off-Desktop label.

The focused suite ran 66 tests: 63 passed and three opt-in native probes skipped.
Desktop discovery/selection probes passed separately. A standalone native test app
verified actual AX omission, correct remote-window focus and minimized restoration,
with 10.9 ms activation in that fixture. Intel/macOS 14 type checking passed.
Third-party apps, fullscreen and multi-display combinations remain unverified, as
does how Mission Control and the Dock present the Desktop after a direct selection;
the probe asserted WindowServer state only.

The clipboard native pipeline reproduced the copy-only warning when an otherwise
editable target omitted `AXSelectedTextRange`. A stronger test using AppKit's real
Paste responder chain also reproduced focus remaining outside the original editor
after the popup closed. The fix accepts missing ranges only with concrete target
identity and editability/native-Paste capability, and restores focus only within
the original still-frontmost app/window. Available range checks, secure/disabled
field guards and input/history-generation cancellation remain enforced.

The initial focused run passed 47 clipboard/selection tests. The final pipeline
suite passes 16 regressions, exercising capture, popup search focus, Return,
restoration and native Paste routing with named pasteboards and synthetic text.
An isolated VS Code 1.141.0 profile verified the integrated terminal under both
`on` and `auto` accessibility support: xterm exposes an editable textbox, its native
Paste menu is enabled, and background terminal output preserves the separate input
identity and caret. Its actual paste handler delivered 24 synthetic characters to
an owned PTY without Return/newline or system-clipboard access. This verifies IDE
input semantics, not macOS AX mapping or cross-process CGEvent delivery; the runner
does not have Accessibility/event-posting permission. TCC was not modified.

The switcher now hides scroll indicators with the native SwiftUI modifier. Eighteen
focused tests and a synthetic 40-row native-host probe verify selection-following,
wheel and precise-pixel scrolling at 500×352, including process-local legacy
scrollbar style. Warm presentation p95 remained 7 ms.

The combined `swift test -c release --disable-keychain` run passed **480 tests**:
98 core, 23 Usage and 359 app tests, with the three opt-in native Spaces probes
skipped and no failures. It was repeated unchanged after the work moved between
agent sessions.

Signed universal **1.0.15 / 20261010180351** was built from `e14cfa4` and installed
at `/Applications/Frog.app`. Its signature, existing signing team, hardened runtime,
both architectures, executable hash and one running installed process were verified.
Configuration bytes, semantic preferences and the downloaded-model inventory were
unchanged, and the superseded bundle was moved to Trash. This is a local build, not
a published release. The installed app's cross-Desktop switching and automatic paste
into a real IDE terminal have not been exercised yet.

## Interaction follow-up after v1.0.15

Final integrated `swift test -c release --disable-keychain` passed **455 tests**:
98 core, 23 Usage and 334 app (including one temporary native visual probe; 454
repository tests). Native captures verify the compact popup, feature settings,
rows-only switcher and “change desktop” settings results. Final fixture timings:
command warm opening/search 14.6 ms, switcher first presentation 8.9 ms (warm p95
7.0 ms), and three Usage provider changes with 200 saved rules 2.4 ms. Public-source
secret scanning, whitespace and local documentation-link checks passed.

Signed universal local **1.0.15 / 20261010155203**, built from `51d8380`, is installed
at `/Applications/Frog.app`. Both architectures, the existing Developer ID team,
strict nested signatures and installed executable hash were verified. JSON and text
configuration bytes, semantic preferences and downloaded-model inventory remained
unchanged; one matching installed process is running. Superseded generated/backup
bundles moved to Trash. This follow-up has not been published as a new GitHub release.

The shared release pipeline published **v1.0.15 / 20261010145748** from
`2e900fed56bd5c6b51329866658e0b86216c54b3`. Its test, universal architecture,
signature, notarization, Gatekeeper, Sparkle and uploaded-download checks passed.
The first attempt stopped on a missing Apple signing timestamp; a normal retry
succeeded. The subsequent changes below are newer than that published release.

Usage's native outside-click test first failed with a semitransient popup; changing
to transient alone did not pass the local-event reproduction. Explicit local/global
click monitors and deactivation dismissal now pass, with inside clicks preserved.
Provider selection first triggered three unrelated history reloads and took about
100 ms for three switches with 200 saved rules. A display-only save path plus ordered
off-main persistence reduces that fixture to 1.47 ms and zero unrelated reloads.
Tests cover a later rule save/import winning over queued preferences, and failed
writes restoring the saved provider while preserving an external configuration edit.

Synthetic light/dark/Tokyo Night captures verify weekly pace text and OpenAI's
Input / Cached input / Output row. Claude and OpenAI summaries fit the 360×360
popup without a scroll view; a short-screen fallback remains. Pace arithmetic
tests cover ahead/on/under pace, reached limits and invalid/expired windows.

Window switching now publishes aged cached rows immediately (about 9 µs lookup in
the fixture), refreshes separately, and runs activation on an independent executor.
The 200-row native first-presentation fixture improved from 38.5 to 12.9 ms after
preloading; a later focused run measured 8.3 ms first presentation and 6.3 ms warm
p95. A blocked-discovery fixture no longer delays activation, and an unresponsive
51-window owner receives two metadata attempts instead of 51. These are synthetic
measurements, not a physical key-to-photon or head-to-head Contexts benchmark.
All 62 focused switcher tests passed, including configurable modifier combinations,
Shift reversal, modifier release, rebinding, cancellation and cached-row ordering.

Navigation tests verify legacy Window/Clipboard links redirect to their Features
cards, Clipboard history remains in History, and window actions stay available
independently of the switcher. The optional System monitor defaults off.

Command-bar profiling with 2,000 synthetic applications measured 48.5→25.6 ms warm
opening in debug (17.2 ms release), 200.7→178.2 ms for 40 query changes (118.3 ms
release), and 830.3→348.6 ms for 79 keyboard-scroll/layout steps (329.0 ms release).
Release opening plus search measured 20.2 ms. Bounded ranking, stable rows and
coalesced asynchronous icons reduce repeated work; stale file results are rejected
without resetting keyboard selection. The 28 focused release tests passed.

Settings search starts with 55 curated destinations and aliases, then enriches them
with installed Apple extension metadata and localized search terms off-main. Local
discovery found 61 destinations in 63 ms. Tests cover natural queries, privacy
anchors, discovery parsing and navigation fallback. Actual pane behavior across
macOS versions and physical trackpad scrolling remain manual checks. Vorssaint's
background-discovery approach informed an independent implementation; no reference
source was copied.

The optional System monitor samples on a utility-priority actor: CPU and GPU every
five seconds while the feature is on, and every two seconds together with disk and
power while its menu view is visible. The graph keeps ten minutes of timestamped
samples (at most 600); disk capacity is cached for 30 seconds. Initial native sampling measured about 7.3 ms
cold and 0.68 ms warm. CPU uses tick deltas; GPU reports the busiest supported
driver statistic; disk I/O covers supported devices, with startup-volume capacity
shown separately. Power source, battery charge, thermal state and Low Power Mode
use native readings. An unsupported GPU remains unavailable. Total-system wattage has
no public reading and no row.

Ten focused tests passed for initial monitor integration, including optional/default-
off behavior, delta calculations, bounded history, visibility, and late-result
rejection. Synthetic battery/desktop/unavailable captures and native menu-height
transitions fit and preserve the top edge; a standalone native probe passed actual
show/hide and close/reopen lifecycle checks. Intel/macOS 14 collector type checking
passed; physical Intel runtime remains unverified.

The power follow-up adds optional native AppleSmartBattery voltage/current conversion
to explicitly labeled battery draw or charging watts. It handles signed/unsigned
registry encodings and rejects missing, zero, implausible or contradictory readings;
this is not total-system or adapter wattage. Fifteen focused tests passed, including
five conversion/availability cases and updated layout transitions. A read-only
native smoke returned valid battery flow; the complete sampler measured about 7 ms
warm off-main. Updated battery-draw/charging captures fit below 520 pt.

## Subsequent desktop polish

`swift test -c release --disable-keychain` passed **386 tests** (87 core,
22 usage, 277 app) after the final changes. Synthetic native popup assertions
also passed for light, dark and Tokyo Night appearances.

Installed signed universal local build **1.0.14 / 20261010144546** from `7cc78ff`
at `/Applications/Frog.app`. Strict nested signature checks and both architectures
passed; installed executable matches the verified build. Configuration bytes,
semantic preferences and downloaded-model inventory remained unchanged, with one
installed process running. Superseded generated/backup app bundles moved to Trash.
This is a local update; the published v1.0.14 release remains the earlier build.

A dynamic native MenuBarExtra fixture reproduces the outer translucent strips:
window height 326 pt, visible panel 252 pt after an async status-row removal. Removing
fixedSize left the mismatch. Explicit content-driven native sizing now produces
252 pt for both, with matching rounded corners. Regression checks cover shrink/grow,
coalescing, top-edge anchoring and non-interception of buttons.
The first resize implementation failed the top-edge assertions because AppKit's
setContentSize retained the bottom edge. Explicit frame sizing preserves maxY;
the regression and actual MenuBarExtra reproduction both pass after that correction.

Command-bar verification uses 2,000 generated applications and a blocked refresh:
cached search remains immediate, moved window geometry survives reopening, and
calculator/Return/Escape and canceled-indexing checks remain covered. A debug warm
open+search measured 28.4 ms; this is a fixture measurement, not a system-wide guarantee.
The final release-mode run measured 22.9 ms for the same warmed fixture.
Spotlight setup saves Frog's shortcut while preserving rules/providers; system
shortcut reassignment is a user action and is not exercised against real settings.

Usage's subsequent compact design is 360×360: full-width limits, inline reset times,
small plan badge and source/pricing details in the dashboard. The two primary limits
fit without scrolling; additional limits are indicated in the footer. Partial API
estimates remain labeled and polling warnings remain available from the status icon.

Clipboard settings now navigate to History → Clipboard. The native history test
follows that route and verifies explicit sensitive-entry reveal/remasking without
persisting clipboard contents.

## Menu-bar follow-up

Native probes reproduced and verified fixes for two organizer defects: a spacer's
new width arriving before its new origin caused immediate reopening, and clearing
its autosave identity before removal left empty remote menu slots. The fixed probe
stays collapsed through layout, preserves adjacent spacing across reveal, and
returns the remote slot count to baseline after cleanup. Deterministic regressions
also verify that genuinely unsafe arrangements recover after the bounded grace.

A synthetic `MenuBarExtra` reproduced the mismatched outer corners. Its native
background siblings extended beyond Frog's SwiftUI clip. Masking the native blur
and borderless content host to the same 12-point outline makes the previously opaque
corner pixels transparent while keeping the content opaque. This capture contains
only a generated menu window. The native backdrop regression checks the host and mask.

The first Usage popup revision was **360×420 points**, down from 440×640, with a smaller chart,
compact quota rows and a total-token summary. Full breakdowns remain in the dashboard.
Height is bounded by the anchor display. Synthetic Frog light/dark and Tokyo Night
captures were reviewed; Tokyo Night includes both light and dark palettes.

The menu-bar follow-up debug and release suites passed **381 tests** (86 core, 21 usage, 274 app), with
zero test failures. Logs and synthetic captures remain outside the public repository.

Installed locally as **1.0.13 / 20261010155029** with settings and downloaded models
unchanged, the same signing team and one installed process. A subsequent native
organizer check measured zero adjacent gap before/after reveal and identical remote
slot counts before/after cleanup (10→10). Old orphaned slots were cleared with a
one-time menu-bar service refresh; the app does not restart system services itself.

The subsequent OpenCode V2/combined OpenAI correction passed the full release suite:
**382 tests** (86 core, 22 usage, 274 app). The signed universal local build
**1.0.13 / 20261010160315** passed isolated startup/quit and strict signature checks,
then replaced the installed app with configuration and downloaded models unchanged.
The parser regression uses generated mixed V1/V2 SQLite rows and Codex logs; it does
not read personal conversations or authenticate against a real account.

Published **v1.0.14 / 20261010140638** through the shared `release-frog.sh` workflow
from source `3f9bb2c45f8c81b1a6f9b1ac8384e65c958f7409`. The script verified the
universal Developer ID-signed, notarized app, ZIP, DMG, Sparkle appcast and downloaded
release assets. Installed that release in Applications; configuration and model
inventory remained unchanged. Superseded generated app bundles were moved to Trash.

README media uses sample data: the feature-overview screenshot is from the website,
and the 24-second recording captures the native SwiftUI view over time in an isolated
fixture. It shows Features, Usage, snippets, notes, Tokyo Night and clipboard history.
No personal desktop or conversations were captured; the opt-in capture probe is
excluded from production and its temporary test link was removed afterward.

## October 10 integration

The final native suite passed **366 tests**: 86 core, 14 usage and 266 app tests,
with zero failures. This includes the hybrid configuration migration/symlink/reload
contracts, theme and accessibility behavior, bounded recording/tail-follow, successful
delivery statistics, fake coding-tool subprocesses, menu-organizer lifecycle, clipboard
selection identity and transient AX/session/wake recovery. The recording stress case
uses 2,000 Unicode lines; the popup stays within 220 points and preserves complete
delivery text. Source-only reference findings are distinguished from live OS evidence
in [the reliability comparison](research/vorssaint-reliability-reference.md).

Codex 0.159.x was additionally exercised against a loopback fixture: successful text,
blocked file read, blocked write and blocked shell execution. These are not authenticated
provider calls. Native permissions, personal clipboards and power settings were not
changed for these tests. Bundled visual checks and installation are separate steps.

Bundled synthetic interaction checks subsequently confirmed Record → Stop → Statistics
(one recording, 12 words, 11.873 seconds and one rule), Menu bar Collapse state changes,
and Installed tools → Use model → saved provider/editor. Light/dark materials and
readability were inspected using only the app and a generated backdrop window.

The bundled run exposed a missing-file path alias issue during migration: Foundation
returned `/private/var` before creation and `/var` afterward. Canonicalizing through
POSIX `realpath` of the nearest existing ancestor fixes the false stale-file rejection.
The new regression and 22 related persistence/reload checks pass, including symlinks.

The signed universal build (arm64 and x86_64) passed strict signature verification,
isolated accessory startup, and absence-of-diagnostic-hooks checks. Installed locally
as **1.0.13 / 20261010101746**. The installer verified semantic preservation across
the text-config migration, unchanged downloaded-model inventory, matching executable,
same signing team, and a single installed process. No push, release or deployment.

## Automated and build checks

The native app builds through Swift Package Manager and Xcode. A successful build is separate from verifying external text replacement or login startup.

Commands:

```sh
swift test -c release
bash scripts/build-app.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project native/Frog.xcodeproj -scheme Frog-macOS -configuration Debug -derivedDataPath .build/xcode build
```

Run frame-budget tests in release mode, matching the packaged app and CI. The workflow also builds the Xcode project in Debug to verify that configuration compiles.

Every test above replaces the model downloader and the inference engines with fixtures. One opt-in test runs the real ones on Apple silicon: it downloads the smallest Whisper and text models (about 430 MB) from Hugging Face into a temporary folder, loads them with WhisperKit and MLX, transcribes a short tone, completes a short text and unloads. Run it after changing the version of WhisperKit, mlx-swift-lm or swift-transformers; it is skipped otherwise:

```sh
FROG_RUN_MODEL_TESTS=1 swift test --filter RealModelTests
```

A few more environment variables change what a test does. Unset, they cost nothing and change nothing. Point the snapshot ones at a temporary location, never into the repository.

| Variable | Test | What it does |
| --- | --- | --- |
| `FROG_TEST_CLIPBOARD_SNAPSHOT` | `ClipboardHistoryTests.testNativePanelShowsFiveEntries` | Writes the clipboard history panel to this PNG path. |
| `FROG_TEST_COMPACT_CLIPBOARD_SNAPSHOT` | `ClipboardHistoryTests.testCompactPanelRendersMixedSensitiveAndFormattedEntriesInLightAndDarkThemes` | Writes `<prefix>-light.png` and `<prefix>-dark.png`. |
| `FROG_TEST_HISTORY_SNAPSHOT` | `HistoryFeedTests.testNativeHistoryMasksRevealsAndRemasksClipboardOnlyFeedWithoutPersistingIt` | Writes `<prefix>-masked.png`, `-revealed.png` and `-remasked.png`. |
| `FROG_TEST_DICTATION_SNAPSHOTS` | The popup tests in `RecordingReadinessTests` | Writes one PNG per dictation popup state into this folder. |
| `FROG_TEST_GRAPH_SNAPSHOT` | `GraphStyleTests.testUsageChartLaysOutAtBothSizes` | Writes `<prefix>-compact.png` and `<prefix>-wide.png`. |
| `FROG_TEST_SYSTEM_SNAPSHOT` | `SystemMonitorViewTests.testSystemTabAndBatteryHeightTransitionsResizeNativeMenuWithoutBottomStrip` | Writes `<prefix>-battery.png`, `-battery-draw.png`, `-desktop.png` and `-unavailable.png`. |
| `FROG_APPEARANCE_EVIDENCE` | `ScrollAppearanceTests.testPopupUsesActiveNativeBackdropAndIndependentSurfaceOpacity` | Writes window and popup previews for each appearance mode and transparency into this folder. |
| `FROG_SCROLL_TEXT_LENGTH`, `FROG_SCROLL_ENTRY_COUNT` | `HistoryScrollPerformanceTests.testLongTranscriptScrollingStaysWithinFrameBudget` | Sets how often the sample sentence repeats in each history entry (5000) and how many entries there are (50). |
| `FROG_RUN_SPACE_FIXTURE=1` | The three `testNative…` tests in `WindowSpacesTests` | Runs the Spaces fixtures, which switch between two existing desktops through private window-server calls. They are skipped otherwise. |

## Desktop acceptance checklist

Use an installed signed app and a disposable document. Record macOS version, architecture, source application/version, provider/model, and result for each case.

- Open menu-bar settings; close/reopen the window; Quit actually exits and releases shortcuts.
- Mr. Usage: enabling creates a second percentage/bar status item and starts collection. Closing, hiding or minimizing the dashboard must leave collection and the item active. Test popup → Dashboard, shared provider/range/metric/login-source choices, combined OpenAI activity from OpenCode and Codex, and config export/import without credentials or readings. Disable/quit must remove the item, close its popup and cancel readers/requests; re-enable must create only one item and collector. Use fixture accounts and records.
- Appearance: check all eleven themes, custom accent, System/Light/Dark, and independent window/popup transparency at both bounds. Command bar, clipboard, dictation, switcher and usage popup must retain a readable tinted backdrop and round-trip preferences.
- Command bar: find Safari's linked bundle and other installed apps with real icons; open Settings, Models, History and Features. Measure cold and warm opening separately; exercise cached results while independent window discovery finishes. No unmeasured latency claim follows from cache reuse alone.
- Actions: check the 28 Other actions against `SystemAction` and 23 window actions against `WindowAction`. Settings actions open native panes, Screenshot opens its controls, and app-menu actions require an enabled Accessibility command. Check thirds, two-thirds and centered sizes on available displays; report app/hardware limitations rather than assuming support.
- Window actions on Chrome and an Electron app land at the requested size without animation.
- Layout picker opens from its shortcut, the Frog menu and the command bar, previews and applies to the window that was in front.
- Drag to snap (macOS 14, or macOS 15+ with "Drag windows to screen edges to tile" off): edges give halves, corners quarters, the top maximize and the bottom thirds, each with a preview; Restore previous size undoes. On two side-by-side displays a window dragged across the shared edge moves without snapping; resting 0.3 s there snaps. A snapped window dragged away gets its earlier size back under the pointer. With macOS tiling on, Frog does not snap at edges, the page shows the note and its button opens Desktop & Dock, and `defaults read com.apple.WindowManager` is unchanged. With the switch off, `sample Frog 5` while dragging shows no `WindowDragMonitor` or `WindowDragTracker` frames; with it on, repeated clicks without dragging show no `AXUIElementCopyElementAtPosition` frames.
- Simple mode end to end, on one display and on two side by side, with Safari, Chrome, an Electron app such as VS Code, Terminal and Finder: on fresh isolated data turn Windows on, choose **Snap** on the choice card with suggested shortcuts (the confirmation names 20 added shortcuts); drag to snap with macOS edge tiling off and, on macOS 15+, on (only the Shift zones apply then); hold Shift mid-drag on each zone grid, release Shift to hide the zones, press Escape to cancel; with macOS edge tiling on, a Shift release at the very left edge is tiled by macOS alone (one move, no flicker) and a release a little inside applies Frog's zone; turning off "Drag windows to screen edges to tile" applies to the next drag without relaunching; a portrait display stacks thirds; ⌃⌥W opens the picker, the cheat sheet lists the shortcuts, Chrome and Electron windows land at the requested size; **Undo** restores the switches and **Set up myself** hides the card and changes nothing else.
- Menu-bar popup: check intrinsic sizing in light/dark modes, with clipboard history enabled/disabled and with an error or recording controls visible. Reopen repeatedly and let status/error/recording rows appear and disappear; the outer window must continue hugging the content. The popup has no window-switcher toggle, RAM graph, or unused vertical gaps.
- Stay awake: starts off; opening/reopening Frog or its popup must not enable it. Use the guided Terminal setup to permit only the two fixed pmset commands. Then verify toggle/readback, timer expiry, normal-quit restoration, unplugged battery cutoff below 20%, permission-denied recovery, and restart cleanup after an interrupted session. A pre-existing setting enabled outside Frog must not be disabled on quit. Lock separately and test lid-closed behavior on the target Mac; automated tests must use injected services rather than real power mutations.
- Stay-awake access: both effective commands must allow passwordless use even without cached sudo credentials. Settings shows checking/ready/setup-needed/unavailable accurately; completed setup hides the popup's setup action. The guide explains changes before confirmation, summarizes validation, and closes only its own Terminal window on success. Reset must restore sleep before launching the guide, empty only Frog's dedicated file after confirmation, and recheck permissions. Test cancellation, permission-check failure, partial access, reset restoration failure, a success marker with missing real permissions, and a failure marker with the permissions present using fixtures; never alter real sudoers for an automated test. The guide's stages are rehearsed against stand-ins for sudo, the power setting and the sudoers file.
- Click the top and edges of **New rule**, create both text and audio rules, and save/reopen them. Window-drag regions must not cover header controls. Create a rule while a search is active: the saved rule must be visible afterward.
- Check shortcut and Command–Tab responsiveness with both the menu and main window open, then with both hidden. Login-item status reads must run off the main thread, share pending requests, and refresh at most once per 30 seconds unless the user changes the setting. Accessibility status must continue updating while the app is in the background. Status-monitor regression tests use a slow service fixture and verify cancellation and a single polling loop.
- Configure a cloud provider with your own key and test it; repeat with Ollama/local compatible service. An invalid key, unavailable model, offline server, rate limit and empty reply produce actionable errors.
- Verify credentials are absent from settings/history files. Blank key retains saved key; explicit removal and provider deletion remove it.
- Assign different providers/models to two rules, and two languages to translation rules; verify each hotkey uses its own settings after restart.
- In TextEdit and a browser text field, select multiline Unicode text, run a rule, verify replacement and clipboard result. The main window stays hidden and focus stays in the source application.
- In Helium/Chromium, repeat with the Accessibility tree initially unavailable. A Copy fallback must use only a fresh selection, preserve the previous clipboard during capture, and leave final results copied. Compare actual edited content, not just an AX success return. Repeat after clicking elsewhere or typing during the request: replacement must be skipped.
- Keep a service menu open for several seconds while permission monitoring runs; icons must remain stable. Delete the last provider with referencing rules, confirm the reset and verify rules remain. In Try text, choose another configured provider/model and verify the saved rule stays unchanged.
- Toggle **Show processing indicator** off/on; hotkey progress must obey the preference and never take focus. Check both success and errors, and confirm manual Try text requests do not show the floating indicator.
- Repeat with no selection, a read-only field, missing Accessibility permission, changed focus, changed selection, and edits during the request. Original text must not be overwritten in these cases.
- Trigger multiple shortcuts rapidly, cancel an in-flight request, and quit while processing. Requests must not cross-apply results.
- Test invalid/duplicate/occupied global hotkeys and remove or disable a rule; registration state must match the UI.
- With a legacy rule assigned Command-C, launch Frog and copy/cut/paste in a disposable document. Clipboard shortcuts must stay with the focused app, with no Frog processing or popup. Assigning these shortcuts to a new rule must be rejected.
- Clipboard history: confirm it starts disabled, enable it in Features, then copy disposable text items. Shift–Command–V (or your configured unique shortcut) must open up to 100 newest items without activating Frog. Copy more than 100 to verify oldest-first eviction and duplicate handling.
  - Ordinary copied text must be readable/searchable without revealing it. Only marked-sensitive previews start hidden; click/Space reveals those, and closing/reopening hides them again. Main History must show the same memory-only items with a Clipboard tag/filter; opening a sensitive entry reveals text and leaving History hides it again. Hidden sensitive contents must not leak through search or accessibility labels. The separate History Hide text preference still applies to ordinary History previews.
  - The compact popup must match Frog's current light/dark theme, resize through eight visible rows, then scroll additional entries. Search and keyboard selection must reach older entries. Ordinary items use a text icon rather than a password/lock icon. Copying new items while open and clearing the list must update its size and selection safely.
  - Click the footer's **Copy** action or press Command-C with an item selected. Its text/formatting must reach the clipboard even without an automatic paste target; no paste should occur. Command-C while editing selected search text should remain a normal text-field copy.
  - Record another valid shortcut, reject ordinary Command-C, then successfully record a valid chord again; show the actual reserved-key/conflict error, not a false missing-modifier hint. Check formatted Paste and Paste without formatting in TextEdit and a browser; arrows/Return/Shift–Return and Escape must work.
  - In Terminal, verify the chosen text actually reaches the prompt, including when its Accessibility Paste menu cannot be read. Terminal's read-only AX text area must still reach the native keyboard fallback after app/window/field/range validation. Disabled and secure fields must remain excluded. This native path requires a trusted app and a disposable target; injected paste-target unit tests alone do not verify it.
  - Copied audio transcripts and writing results must enter the feed, but temporary compatibility Copy/restoration must not. Concealed/transient-marked text must remain memory-only and preserve a concealed marker when copied or pasted plainly; copied from Frog it must not arrive on another device through Universal Clipboard, while an ordinary item still does. Changing app/window/field before delivery must leave copy only. Clear/delete/disable/quit must remove entries and invalidate pending reads/paste. Re-enabling must not ingest the old clipboard. Clipboard entries must be absent from exports and disk even when saved transformation history is enabled. Ordinary Command-C/X/V and Command-Option-Shift-V stay with the focused app; Shift–Command–V is restored when clipboard history is disabled.
- Local workflows: automated fixture tests cover config migration, action routing, incomplete download cleanup, the free-space check before a download, download progress by bytes with its speed and time left, the measured disk use of downloaded models, the check that a download has the files its runtime needs, Check files and Repair, installed-state recovery, idle unload and cancellation/stale completion during insertion. `swift scripts/check-metal.swift <bundled default.metallib>` verifies actual shader loading without microphone/desktop access; `scripts/build-app.sh` runs it on the bundle it has assembled and stops when the library does not load, except on CI (`CI` set), where runners may have no Metal device. The opt-in `RealModelTests` above covers the real download and inference path. Xcode package-plugin validation may require approval for MLX's CUDA build plugin (inactive on macOS); scripted builds can use `-skipPackagePluginValidation` after inspecting that pinned plugin.
- Download a text model of a few gigabytes and a Whisper model, and watch their rows in Models and in Setup: the bar must move with the bytes, not jump over the small files at the start; the line under it must give the bytes of the model's size, and after a few seconds the speed and the time left. Turn off Wi-Fi: within a few seconds the line must say **stalled**, and the speed must come back when the connection does. Once the files are in, the row says **Preparing…** without the line.
- Remove a tokenizer file from a downloaded text model's folder and empty one of its weight files, then choose **Check files** in its menu: the row must name both and offer **Repair**, which downloads with the usual bar and is followed by a check that passes. The model must stay downloaded and its rules keep it meanwhile; a dictation or request that needs it during the repair must say that it is being repaired. Check an untouched model: it must say that all files are present and match.
- Download speech and cleanup models; record with both toggle and hold modes, view partial text and stop/cancel hints, disable popup, verify copy/paste and shared-history behavior. Exercise missing/disconnected microphone, cancellation during permission/model load/paste, and model idle unload. Verify application launch/focus and the momentary shortcut reference. These live behaviors are separate from fixture tests.
- With models unloaded, start dictation: show Preparing and the model being loaded, keep the microphone closed and timer hidden until every required local model is ready. Release a hold shortcut during preparation: recording must never start later. Once the microphone opens, the popup must keep saying **Starting microphone…** until the microphone delivers its first sound and only then say **Listening…**; check it with a Bluetooth input, and again after choosing another microphone in the popup. Disable cleanup and confirm no text model is prepared; required models must stay resident throughout recording.
- Stop a long recording and press its shortcut again at once, in toggle and in hold mode: no new recording starts before the first is delivered, and the popup says **Still transcribing…** or **Still cleaning up transcript…**. With the popup hidden, the processing indicator says so instead, unless **Show processing indicator** is off.
- Stop a recording with an external speech model while offline, and make a local final pass fail after a recording longer than a minute: the popup must appear even when the rule hides it, say **Transcription failed** with the reason, and keep the recording. Retry must deliver the full transcript without recording again; Copy partial text must copy only what was already recognised and keep the recording; the close button, Cancel recording and quitting must discard it without a History entry. Escape pressed in another app and the rule's shortcut must leave it untouched. A missing key, a rejected model, an empty recording or a local recording shorter than a second must still end the session with its error.
- Enable **Mute Mac audio while recording** and record: the Mac must be silent while recording and sound again afterwards, also after cancelling. Repeat with an output that has no mute control: the recording must start with sound still playing, the reason must be shown once and not again before the next recording.
- Pause speaking with a connected microphone: silence must not show "No microphone input". Stop audio-buffer delivery or disconnect the input that is recording and verify the warning appears after two seconds and recording continues on the macOS default input, which the popup selects; the warning clears once that input delivers sound, and both inputs' audio is transcribed. With the popup hidden, Frog says once that it switched. The saved microphone must stay unchanged, and an input that has not delivered its first sound yet (a slow Bluetooth start) must not be replaced.
- Disconnect the saved microphone before starting dictation: recording must start on the macOS default and the popup must select System default. Switching inputs in the popup must preserve captured audio and save an explicit choice, including choosing the already-active System default. Automatic fallback alone must preserve the saved preference for reconnection.
- Switch Local/External in an audio rule's model picker, including an empty source and clicks beside the labels inside each tab. Installed choices must appear promptly without loading weights, with download sizes and Recommended labels. Delete a selected model: Frog must first ask, naming the model, its download size and what becomes of the rules that use it, and Cancel must leave the download and the rules untouched. After confirming, verify affected rules choose another compatible model; local rules stay local. Save an already-open editor and restart with an older missing-model selection: neither may restore the deleted selection, and unrelated draft edits must survive. Check Settings → Local models and copy an error or the complete log.
- Repeat model recovery after a download folder is changed or the selected download has already disappeared from disk. Settings must say how much the downloaded models use next to the model folder, and the figure must change after a download, a deletion or a folder change. Choosing another folder while models are downloaded must first ask, naming how many stay in the current folder and the space they use; Cancel must leave the folder unchanged, and choosing the same folder again or choosing with nothing downloaded must not ask. Choosing a folder without models, or starting with the model folder unreachable, must leave every rule its model, shown as not downloaded, and choosing the former folder, or the same folder again once its disk is connected, must make the rules work again without editing them. Deleting the last speech model must leave an editable rule with an explicit model-selection message; it must not start recording with a missing model.
- Window switcher: open several windows in one app plus another app, hold Command and cycle with Tab/Shift–Tab/arrows, then release to activate the exact selected window. Test Escape, Return, hovering/clicking a row, rapid press/release before discovery finishes, closing a target during discovery, hidden/minimized targets, and other Spaces/full-screen applications. Opening/cancelling the overlay must not activate Frog or change the source window.
- Disable window switching, quit Frog, revoke Accessibility, and enter shortcut-recording mode: interception must stop and the native shortcut must remain available. An enabled writing rule assigned Command–Tab must retain its shortcut and show the conflict in Windows. Permission/status polling must not redraw unchanged menus.
- Type continuously in a disposable text field with Frog running, including while its settings are open or busy. Input must remain smooth and ordinary keys must schedule no switcher UI work. Compare tagged synthetic input latency with Frog closed; a deliberately busy Frog UI thread must not delay delivery in another app. Verify background scans pause while typing and Command–Tab refreshes an aged inventory, including newly opened/closed windows. Repeat enable/disable and quit to check input-thread teardown.
- Enable history, process manually and by hotkey, relaunch, inspect/copy/delete/clear records. Disable recording during a request; its result must not be recorded. Verify configured bounds/expiry.
- Scroll History with many long transcripts: compact previews must stay responsive, while copying/searching still uses complete text. Opening an entry longer than 20,000 characters must also stay responsive: it shows the text a page at a time, and **Show more** must reach all of it without losing or repeating a character. The isolated native scroll regression measures UI/layout time separately from timer scheduling and uses synthetic history only.
- With History enabled, press Escape during recording, transcription and cleanup. The microphone/popup must stop immediately; one entry marked **Interrupted · Esc** must receive the full raw transcript in the background without copying, pasting or running cleanup. Open the entry while it transcribes and verify it updates in place. Start another recording during recovery; neither transcript may alter the other. Cancel buttons use **Interrupted**. Disabled History must not start recovery; deleting/clearing history or disabling it must cancel pending recovery and never restore removed entries. A failed recovery retains available text and shows its failure; old history still loads.
- Export a configuration, edit a rule and import it again. Verify the replacement summary, backup file, provider routing and shortcut registration. Invalid JSON/references/shortcuts leave current settings untouched. Exported JSON contains neither API keys nor text history. Re-enter keys for new/changed connections on import.
- Launch normally and at login: confirm the menu icon appears without a settings window or Dock icon. Open/close/reopen settings explicitly; closing must leave Frog running. Enable Start at Login for `/Applications/Frog.app`, inspect Login Items approval, log out/in and confirm the same quiet startup. While macOS still waits for that approval, Settings keeps the toggle on, says so under it and offers **Open Login Items**; the note must disappear once Frog is allowed and Frog is brought forward again. Disable startup and confirm removal.
- Confirm Frog never requests notification permission or sends system notifications. Errors stay in the app and can be copied from Settings → Logs.
- Measure idle CPU/RSS after startup and with settings closed; verify no inference engine is launched by Frog. Resource budgets are measured evidence, not a hard-coded marketing claim.

## Toolkit walkthrough evidence

The October 9, 2026 native walkthrough used isolated settings, a named clipboard,
synthetic usage/documents and private clones of downloaded Qwen and Parakeet models.
Native clicks and captured app-window screenshots verified:

- Writing → Try → Run with real Qwen inference and a corrected result.
- Dictation → Record → Stop with synthetic speech through the real Parakeet runtime.
- Command-bar calculation, percentage, unit conversion and exact-note navigation.
- Usage parsing and feature disable/re-enable under the then-current visible-page
  lifecycle. October 10 superseded this with continuous collection while enabled;
  the earlier close/reopen result is not evidence for the new status item lifecycle.
- Script execution and result ownership; new scripts do not display another script's output.
- Compact clipboard controls, pinned workspace navigation and light/dark surfaces.

The earlier unbundled visibility check skipped when WindowServer did not expose its
window; packaged close/reopen observations covered that earlier implementation.
Synthetic speech validates runtime/UI integration, not physical microphone capture.
Real power settings and provider credentials were not changed for this walkthrough.
The later menu-bar follow-up above records the native geometry reproductions.

October 10 feedback verification used the bundled native app with the same isolation:

- The Usage status item and collector remained active after closing the main window;
  disabling removed both, and re-enabling restored them. Period selection survived restart.
- Compact Usage dashboard/popup, source labels, quota meters and charts were inspected
  in light, dark and Nord themes. Dropdown selection worked through native clicks.
- Safari resolved with its icon; Settings and calculator search worked. Presentation
  calls measured 51 ms cold / 9 ms warm for command search and 45 / 4 ms for clipboard.
- Parakeet prepared in 7.97 s cold, under 1 ms resident, and 363 ms after unloading;
  Record/Stop produced the expected synthetic transcript.
- The integrated suite passed 287 tests without failures (66 core, 9 usage, 212 app).
  Actual permission-gated hotkeys and window switching require separate verification.

## Organizer and Usage follow-up — October 10

- Three organizer regressions first failed with five assertions: mid-drag spacer
  resizing, temporary missing frames discarding collapsed state, and settings changes
  hiding an unvalidated permanent divider. Fixed with drag/frame deferral and order
  validation. Native NSMenu tests cover actions, checked auto-hide, persistence
  callbacks and paused tracking. The isolated organizer/preferences suite passes
  17 tests. Synthetic Settings snapshots cover light/dark appearance.
- Usage fixtures reproduced immediate-refresh and account-range bugs before fixes.
  Added coverage for lifetime/history separation, custom profile discovery/export
  isolation, DB/WAL changes, failed reads, recovery and deletion. Synthetic dashboard
  and bounded popup captures cover light/dark and scrolled detail sections.
- Full integrated `swift build`, `swift test` and `swift test -c release` pass:
  **379 tests** (86 core,
  21 usage, 272 app), zero failures. Earlier intermediate SwiftUI type-check failure
  resolved. Evidence: `frog-usage-parity-integrated-tests.log`,
  `frog-organizer-reliability-{red,green}.log`, `frog-organizer-visuals/`, and
  `frog-usage-parity-visual/` under the approved temporary directory. The final
  optimized suite is recorded in `frog-public-push-release-tests.log`.
- Signed universal local build **1.0.13 / 20261010141144** passed strict signature,
  arm64/x86_64, diagnostic-hook absence, isolated accessory startup and normal
  termination checks. Installation preserved semantic configuration and downloaded
  model inventory, retained the signing team, and verified one installed process
  with the matching executable. The Xcode Debug project build also passes.
- Real-account parity and live Command-drag/notch behavior remain unverified.
  Source comparison and precise remaining Usage limitations are documented in
  `docs/usage-integration.md`. Diagnostics did not use personal logs, authenticated
  prompts, permission grants or desktop screenshots. Temporary hooks are absent from
  production Swift sources; `git diff --check` passes.

## Organizer on external displays and minimized windows — October 11

- On an external display in macOS 26 the menu bar is 30 points tall while the
  status-bar thickness is 22, and every status item's window gains 8 points on each
  side. Frog compared the arrow's window with a 22-point band, read it as off-screen
  and kept the organizer revealed. The band now follows the space the screen reserves,
  the safety check uses the arrow's centre and horizontal fit, and the helpers shrink
  by the system's padding. Tests failed first with the measured geometry. The
  installed build auto-hid after its 10-second delay on a 2560×1440 display and
  toggled from a click in the arrow's padding.
- The window switcher could not restore a minimized window: its existence check used
  an on-screen window list, and the raise right after un-minimizing could time out
  while the owner animated. Lookup by window ID and a bounded raise retry fixed a
  live reproduction; the window was minimized again afterwards.
- Focused suites pass: 22 organizer tests and 33 window tests (3 opt-in Spaces
  fixtures skipped). Diagnostics logged geometry only, never window titles.

## Quick switch between two apps — October 11

A single Command–Tab sometimes landed on a third app. The switcher picked the row
after the frontmost window in its warm list, and that list can lag: scans pause while
typing, and a keystroke or a second Command–Tab retires a pending activation before
its focus is recorded. The frontmost window now leads the warm list before cycling
starts, and the next scan ranks it the same way. Two tests failed first with the
third app selected; 57 switcher tests pass. Not reproduced live.

## Claude limits without a current login, and password prompts — October 13

- **Mr. Usage showed day-old limits and then only the API estimate.** Nothing on the
  Mac could supply a reading: the login source was `Claude Desktop`, the Claude app's
  file was three days old and Claude Code's login had expired. Frog now lets Claude
  Code renew its own login in the background and offers "Sign in to Claude Code…";
  details and limits in [usage integration](usage-integration.md). 28 usage tests and
  the launcher test pass with fakes. A real renewal and the Terminal launcher were
  not exercised: the login on this Mac can only be restored by signing in.
- **Window switcher dead while a password prompt is open.** Not reproduced with the
  reported app. The explanation is macOS secure keyboard entry: while any app holds
  it, key events reach that app only and Frog's event tap receives nothing, so
  Command–Tab falls through to macOS. A synthetic probe process confirmed the
  detection used (`IsSecureEventInputEnabled`, owner from `kCGSSessionSecureInputPID`
  in the session dictionary and the IORegistry). Frog now reports "Paused — <app> is
  asking for a password" in Features, shows a five-second notice once the prompt has
  been left in the background for 1.5 seconds (again after an app switch, at most
  every five minutes), stays silent while the user types into the prompt or into
  Frog's own fields, and closes an open overlay when secure entry begins. 5 notice
  tests and the 3 lifecycle tests pass. Key delivery under secure entry could not be
  exercised from this shell (no Accessibility or event permissions), and the notice
  was not seen on screen with a real prompt.
- **Not built:** keeping Command–Tab working during a prompt. Public APIs cannot; the
  known route switches off macOS's own Command–Tab through a private window-server
  call and registers a Carbon hotkey instead. Left for the user to decide.

## Quick toggling between two windows lands on a third — October 13

Reported again after the October 11 change, with the hint that it follows a small
movement of the mouse. Two causes were found by reading the code; neither was
reproduced live (this shell has no Accessibility or event permissions).

- **The pointer chose a row.** The list appears at once in the middle of the screen,
  usually under the pointer, and any pointer movement over a row, one point included,
  selected that row; releasing Command then switched to it. The pointer now selects
  only after it has rested for 350 ms since the list appeared or a key moved the
  selection, and has then travelled 16 points (`WindowSwitchPointer`). Movement during
  the rest does not count, a pointer that stays put never selects, and a click on a
  row works at any time. 3 tests cover the nudge, deliberate movement and a key press
  taking the selection back.
- **The front window was guessed.** When the next Command–Tab arrives before the
  previous switch was recorded, the warm list led with the first window it knew of
  the front app. If that app has several windows this could be a different one than
  the window just chosen, which then counted as recently used and became the next
  target. The switcher now remembers the window it was asked to bring forward until
  a focus reading replaces it. One test failed first with the app's other window
  selected; 2 tests cover it.
- 24 tests in the two affected suites pass. Not changed: a held Tab repeats after the
  system's key-repeat delay and steps further, as in the macOS switcher; a window that
  misses one inventory still returns with a new identity and no rank.

## Graphs in the style of Linear's project graph, CPU/GPU recorded out of sight — October 13

Request: the CPU/GPU and LLM usage graphs in the design of Linear's project graph, and
the CPU/GPU graph already holding data when its tab is opened.

- **Look** (`GraphStyle.swift`): a legend of small squares with the value below, a
  thin smooth line over a fading fill, thin bars on the baseline, a time axis that
  names only its two ends, no grid and no value scale. The pointer shows the exact
  values. The System tab draws CPU and GPU in one graph over the last ten minutes;
  the two lines keep one colour each instead of changing with the load. The activity
  chart of Mr. Usage draws the period's running total as the line and each day's or
  hour's amount as a bar on its own scale.
- **Recording** (`SystemMonitor`): while the feature is on, CPU and GPU are sampled
  every five seconds whether or not the menu is open; disk and power are still read
  only while the view is visible, every two seconds. Samples carry their time, so a
  missing reading or a pause over 30 seconds (sleep) breaks the line instead of being
  bridged. What is recorded out of sight is not published until the view shows, so a
  menu that stays mounted after closing is not redrawn. A CPU reading asked for less
  than half a second after the last one repeats it; a late background wake-up up to
  30 seconds still counts as the average over that stretch.
- 17 tests in `SystemMonitorTests`, `SystemMonitorDeltaTests`, `SystemMonitorViewTests`
  and `GraphStyleTests` pass. They cover recording while hidden, the history being
  there on the first frame, keeping the baselines across open and close, the
  ten-minute window, a clock set back, line breaks, and the running-total maths.
  Synthetic renders of the System tab (battery, desktop, unavailable) and of the
  activity chart at popup and dashboard width, dark and light, were inspected.
- The real sampler was probed once: a sample taken out of sight (one
  `host_processor_info` call and one IOAccelerator registry read) took 0.35 to 0.58 ms
  and returned plausible CPU and GPU load.
- Not verified from this shell: pointer hover on the live graphs, the real cadence of
  the five-second timer under timer coalescing, and the energy impact macOS reports.

## Claude limits still missing after the fixes shipped — October 13

Report: "the llm tracking still is not really working". Checked on the reporting Mac
without changing its settings or logins:

- The installed Frog was **1.0.22**; Sparkle had staged 1.0.23 and was waiting for
  Frog to quit. None of the 1.0.23 to 1.0.25 changes were running.
- The Claude app's menu-bar icon was switched off, and the app saves its limits only
  while that icon is on and was opened recently. Its last saved reading was three
  days old.
- Claude Code reported no login, so no background renewal was possible.

Change: an update that waits for Frog to quit is now named in both menu-bar popups
("Update to x is ready…") and in Settings → Updates ("Install and Relaunch…"), and
the Claude-app status states what the app's saving depends on. Details in
[usage integration](usage-integration.md).

- `swift build` passes. 24 usage tests (`ClaudeDesktopUsageTests`,
  `ClaudeLoginRenewalTests`) and 3 app tests (`UpdateReadinessTests`, the popup
  sizing test and the outside-click test) pass.
- Read in Sparkle 2.10.0's source: returning `false` from `willInstallUpdateOnQuit`
  leaves installation on quit unchanged, and a user-initiated check while an update
  is staged shows the alert with "Install and Relaunch".
- Not verified live: a real Sparkle cycle calling the delegate, the row in the
  running app, and the prompt opened from it. Still open from 1.0.23: a real Claude
  Code renewal and the Terminal sign-in launcher.

## Several Claude accounts — manual checks

Use an isolated `FROG_DATA_DIRECTORY`; the usage defaults suite holds only polling
state and can stay as it is. Do not finish a Claude Code sign-in for another account
unless you mean to.

- With two Claude app folders (such as `Claude` and `Claude-Account-B`), the offer
  appears once in the popup and on the page. **Not now** hides it, also after a
  relaunch; the switch stays on the page.
- **Show both** shows `A …%  B …%` in the menu bar; the tooltip lists each account and
  window with its source and age.
- Renaming B to "Work" on the page shows "Work" in the menu bar (at most six
  characters) and in the popup.
- *Combined*: the popup reads "Plan limits · A + B", each bar has a breakdown such as
  "A 30% · B 80%", and no bar has a pace mark or renewal time.
- **Include** off for B removes B from the menu bar and from the combined values.
- **Set up live readings…** explains first; **Open Terminal** opens a Terminal window
  running Claude Code's sign-in with `CLAUDE_CONFIG_DIR=…/.claude-account-b`.
- Switch off: the menu bar item, the popup and the page look exactly as before,
  including the login source menu and the "Claude Code profile" line.
- No e-mail address is visible on the page or in the popup without hovering.

## Answer rules and older versions

A text rule that answers in a panel stores `action.textOutput: "panel"`. Frog versions
before Explain ignore that field and treat the rule as a Writing rule. If such a rule
has a shortcut, pressing it in an older Frog that reads the same configuration replaces
the selection with the answer. The built-in Explain rule has no shortcut, and the rule
editor warns when an answer rule gets one.

Answer rules never run through Writing: the Writing page does not list them, and running
one through the Writing path is refused before anything is captured or sent
(`ProcessingTests`, `HotkeyRulesTests`). With Explain off they register no global shortcut
and their shortcut does nothing; with Explain on they answer in the panel
(`ExplainRoutingTests`).

## Explain answers in a panel — October 16

Automated: `AnswerPanelDismissalTests` (every event, pinned and not), `ExplainSettingsTests`
(defaults, `explain.context` round trip, nothing rendered until edited) and
`ExplainRoutingTests` (nothing runs while Explain is off; the Explain rule is added once;
the request holds the selection, surrounding text and app name but never the page
address; no surrounding text with the setting off; Writing rules still complete and
replace; turning Explain off closes the panel and cancels the stream; a Frog model is
labelled "name · Frog"; answer shortcuts follow Explain), plus `ProcessingTests`,
`AnswerControllerTests`, `CommandBarResultsTests`, `HotkeyRulesTests` and the
configuration and feature tests. `RuleEditorTests` and `RulesWorkflowTests` open windows
and run separately.

Device checks, with an isolated `FROG_DATA_DIRECTORY` and a throwaway provider entry or a
downloaded local model, still to run:

- [ ] Turning Explain on adds the Explain rule with a model; giving it a shortcut shows
      the warning in the rule editor.
- [ ] Selecting a word in Safari, TextEdit, Notes, Xcode and Terminal and pressing the
      shortcut opens the panel next to the word within a second, and the answer streams.
- [ ] The frontmost app stays the same, and typing continues in the original field after
      the panel appears, after a follow-up is typed and after the panel closes.
- [ ] Escape, a click outside and switching apps close an unpinned panel; a pinned one
      stays and can be dragged.
- [ ] Slack or VS Code (compatibility Copy): the panel opens at the pointer and the
      clipboard is restored.
- [ ] Placement on two displays (one with a negative origin), in full screen and across
      Spaces.
- [ ] Streaming and the model label with Ollama, a cloud provider, a Frog model, and
      Claude Code (one piece).
- [ ] VoiceOver reads the panel as "Explain answer" and announces "Answer ready".

### Answers in History

Automated: `AnswerRecordTests` (an entry keeps the selection, first answer, sent context,
app, address and follow-ups; history written before answers still loads; an entry without
an answer writes no `answer` key), `HistoryFeedNarrowingTests` (answers under Answers,
Writing under Text, search over context, app, address and follow-ups, hidden copied text
still unmatched, when the Answers filter shows), `HistoryEmptyStateTests` ("No answers
yet") and `ExplainRoutingTests` (one entry per answer that its follow-ups update; nothing
saved with History off, turned off or cleared during an answer, or for a failed or
stopped answer).

Device checks, with History on and isolated data, still to run:

- [ ] Ask, follow up twice, open History → Answers: one entry with two follow-ups; search
      finds a word of a follow-up.
- [ ] Clear history while the panel is open, ask a follow-up: no entry comes back.
- [ ] Hide text in History hides answer rows and details until revealed.

### Answers saved to notes

Automated: `AnswerNoteTests` (file names, the daily file pattern and its refusals, front
matter and sections byte for byte, quoting, a shortened long selection, no surrounding
text), `AnswerNoteWriterTests` (no overwriting, folders created, one blank line between
sections, a missing folder, a file over 5 MB, symbolic links out of the folder refused),
`NoteOpenerTests` (Obsidian or the file, the vault search stops at the home folder),
`ExplainSettingsTests` (the five keys, a folder path too long for the text file kept in
config.json, validation) and `ExplainRoutingTests` (notes off refuses, the folder is asked
for once and stored, saving with History off, the panel's Saved and failure states, a
cancelled folder choice).

Device checks, with isolated data, a throwaway folder and a throwaway Obsidian vault, still
to run:

- [ ] One note per answer, then the same selection again: a second file with " 2".
- [ ] Add to one note into `Daily/YYYY-MM-DD.md` while `Daily` does not exist yet.
- [ ] Open the note after saving opens it in Obsidian inside the vault, in the Markdown app
      outside it.
- [ ] A folder in iCloud Drive (macOS may ask for access once).
- [ ] Obsidian shows the front matter as properties.
- [ ] ⌘S in the panel and Save to note in History's answer detail; with no folder, the
      chooser opens and the panel stays open.

### Answers read without copying

Automated: `SelectionReadDecisionTests` (password fields, no range, a caret empty only in
text areas and text fields, too long before any text is read, marker text),
`SelectionReaderTests` (fake elements: a text field's text, rectangles and fingerprint; a
password field refused without reading text; a web area read through text markers and a
caret there unavailable; the web area found within eight parents; context only when asked
and a long value read only around the selection; the live source splits a real marker
range into its first and last marker, in order), `SelectionIsolationTests` (the reader
names no pasteboard, Copy or event posting) and `ExplainRoutingTests` (a selection read
this way never copies; empty, secure and too long refuse without copying; unavailable
falls back to the compatibility Copy).

Device checks, with isolated data, still to run:

- [ ] Explain from its shortcut in Safari leaves `NSPasteboard.general.changeCount`
      unchanged and the panel opens next to the selection.
- [ ] TextEdit with only a caret: "Select some text first."
- [ ] Slack or another Electron app: the compatibility Copy runs and the clipboard is
      restored.
- [ ] A password field: refused.

### Selection bubble

Automated: `ExplainSettingsTests` (the five keys round-trip through the text file, the
longest selection is clamped, an invalid excluded app is refused with its message, the list
is written sorted), `SelectionWatcherTests` (a drag reads once without context after the
settle and shows the rules at the end of the selection; a later input cancels the read;
busy, secure input, excluded apps, games, Frog frontmost and missing Accessibility never
read; empty, secure and whitespace selections show nothing; Escape keeps the same selection
away and another key does not; the selection shown last comes back only when a gesture
selects it again, with Shift and the arrow keys too, or after a plain click or a key took
it away, not after a window drag or a Shift release with Command or Control; a keyboard
selection without a position shows nothing; idle dismissal after six seconds unless
hovered; a choice runs for the bubble's selection),
`ExplainRoutingTests` (the watcher runs only with Explain, the bubble and Accessibility on
and follows a change of Accessibility; an answer from the bubble reads again with context and
never copies; a Writing rule from the bubble runs like its shortcut) and
`SelectionIsolationTests` (the watcher, controller and view name no clipboard, Copy or
posted event).

Device checks, with isolated data, still to run:

- [ ] With the bubble off, no global monitor exists.
- [ ] The bubble appears within about 0.5 s in Safari, Notes, Mail, Xcode, TextEdit and
      Terminal.app.
- [ ] It does not appear in a password field, `sudo` in Terminal, 1Password or a game.
- [ ] With **Chrome and Electron apps** on, in Chrome, a Chromium browser such as Helium,
      Slack and Obsidian, it appears from the first or second selection on, at the end of
      the selected text, also on a page that is not editable.
- [ ] In VS Code and Cursor with `editor.accessibilitySupport` on `auto`, selecting text
      leaves the status bar without "Screen Reader Optimized"; no bubble appears there.
- [ ] `NSPasteboard.general.changeCount` is unchanged across selecting, the bubble
      appearing, and Explain run from it.
- [ ] The frontmost app and its focused field are unchanged; typing continues in the field.
- [ ] Keyboard selection (Shift and the arrow keys) shows it after Shift is released; typing
      capital letters shows nothing.
- [ ] After the bubble went away, dragging the window by its title bar or its scroll bar,
      and pressing ⇧⌘T, bring nothing back; double-clicking the same word again does, and
      so does selecting the same word again with Shift-Option-Right after Left.
- [ ] More expands the bubble inline; a Writing rule from it replaces the selection.
- [ ] Activity Monitor Energy Impact over 10 minutes of normal work, bubble on and off:
      ___ / ___.

## App cleaner

Automated: `CleanerPreferencesTests`, `CleanerFeatureTests`, `CleanerModelTests`, `CleanerCommandTests` and
`CleanerCommandBarTests` run the cleaner against fixture folders with a fake Trash and system. Manual checks on
a real Mac, built with `scripts/build-app.sh`, with `FROG_DATA_DIRECTORY` set to a temporary folder and only a
sample app:

- [ ] With a fresh data directory, Features shows "App cleaner" off; turning it on adds the sidebar entry and the command-bar route "App cleaner".
- [ ] Turning it off while a scan or the confirmation sheet is open closes them without moving anything.
- [ ] The sample app appears; search finds it by name and bundle ID; "Size" sorts it.
- [ ] Its review shows the sample folders as sure or likely, ticked, with reasons and sizes.
- [ ] Dropping the sample app from Finder opens the same review; dropping a text file says "Drop an app from Finder."
- [ ] "Move to Trash…" lists every item; Cancel moves nothing.
- [ ] Confirming moves the app (through Finder; note whether macOS asked for Automation) and the folders; Finder's Trash shows them and offers Put Back.
- [ ] With the sample app running, Frog quits it first; with Full Disk Access missing, the notice appears and "Not now" hides it for good.
- [ ] Owner: remove a small App Store app and a package-installed app with a launch daemon; Finder asks for the password, the daemon note appears, and nothing outside the review list moves.
- [ ] With the cleaner off, typing "uninstall cleaner sa" in the command bar shows no Uninstall row. With it on, "Uninstall Cleaner Sample" leads the list with the app's icon; Return opens Frog on the sample's review, and nothing moved.
- [ ] "uninstall finder", "uninstall notes" and "uninstall frog" offer no Uninstall row.
- [ ] After moving the sample, "Recently moved" lists it with its item count and size; Put Back returns the app and its folders to their places, the app is listed again, and a second Put Back is disabled.
- [ ] The outcome of a removal offers Put Back, which shows how many items came back in place of the outcome.
- [ ] Move the sample again, then drag one of its folders out of the Trash by hand: Put Back says "It is no longer in the Trash." for that item and puts back the rest.
- [ ] "Remove from this list" forgets the record and leaves the Trash as it was. At the end, move the sample app and its folders to the Trash.
<!-- slot: cleaner-leftovers -->
<!-- slot: cleaner-junk -->
<!-- slot: cleaner-assist -->
<!-- slot: cleaner-disk -->
<!-- slot: cleaner-startup -->

## Distribution

Developer ID signing/notarization requires the owner's Apple Developer credentials. Ad-hoc signing is suitable for local development, but is not notarization and does not establish that macOS will trust a downloaded release on another machine.
