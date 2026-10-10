# Native verification

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

The Usage popup is now **360×420 points**, down from 440×640, with a smaller chart,
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

## Desktop acceptance checklist

Use an installed signed app and a disposable document. Record macOS version, architecture, source application/version, provider/model, and result for each case.

- Open menu-bar settings; close/reopen the window; Quit actually exits and releases shortcuts.
- Mr. Usage: enabling creates a second percentage/bar status item and starts collection. Closing, hiding or minimizing the dashboard must leave collection and the item active. Test popup → Dashboard, shared provider/range/metric/login-source choices, combined OpenAI activity from OpenCode and Codex, and config export/import without credentials or readings. Disable/quit must remove the item, close its popup and cancel readers/requests; re-enable must create only one item and collector. Use fixture accounts and records.
- Appearance: check all ten themes, custom accent, System/Light/Dark, and independent window/popup transparency at both bounds. Command bar, clipboard, dictation, switcher and usage popup must retain a readable tinted backdrop and round-trip preferences.
- Command bar: find Safari's linked bundle and other installed apps with real icons; open Settings, Models, History and Features. Measure cold and warm opening separately; exercise cached results while independent window discovery finishes. No unmeasured latency claim follows from cache reuse alone.
- Actions: check the 28 Other actions against `SystemAction` and 23 window actions against `WindowAction`. Settings actions open native panes, Screenshot opens its controls, and app-menu actions require an enabled Accessibility command. Check thirds, two-thirds and centered sizes on available displays; report app/hardware limitations rather than assuming support.
- Menu-bar popup: check intrinsic sizing in light/dark modes, with clipboard history enabled/disabled and with an error or recording controls visible. Reopen repeatedly and let status/error/recording rows appear and disappear; the outer window must continue hugging the content. The popup has no window-switcher toggle, RAM graph, or unused vertical gaps.
- Stay awake: starts off; opening/reopening Frog or its popup must not enable it. Use the guided Terminal setup to permit only the two fixed pmset commands. Then verify toggle/readback, timer expiry, normal-quit restoration, unplugged battery cutoff below 20%, permission-denied recovery, and restart cleanup after an interrupted session. A pre-existing setting enabled outside Frog must not be disabled on quit. Lock separately and test lid-closed behavior on the target Mac; automated tests must use injected services rather than real power mutations.
- Stay-awake access: both effective commands must allow passwordless use even without cached sudo credentials. Settings shows checking/ready/setup-needed/unavailable accurately; completed setup hides the popup's setup action. The guide explains changes before confirmation, summarizes validation, and closes only its own Terminal window on success. Reset must restore sleep before launching the guide, empty only Frog's dedicated file after confirmation, and recheck permissions. Test cancellation, permission-check failure, partial access, reset restoration failure, and a success marker with missing real permissions using fixtures; never alter real sudoers for an automated test.
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
  - Copied audio transcripts and writing results must enter the feed, but temporary compatibility Copy/restoration must not. Concealed/transient-marked text must remain memory-only and preserve a concealed marker when copied or pasted plainly. Changing app/window/field before delivery must leave copy only. Clear/delete/disable/quit must remove entries and invalidate pending reads/paste. Re-enabling must not ingest the old clipboard. Clipboard entries must be absent from exports and disk even when saved transformation history is enabled. Ordinary Command-C/X/V and Command-Option-Shift-V stay with the focused app; Shift–Command–V is restored when clipboard history is disabled.
- Local workflows: automated fixture tests cover config migration, action routing, incomplete download cleanup, installed-state recovery, idle unload and cancellation/stale completion during insertion. `swift scripts/check-metal.swift <bundled default.metallib>` verifies actual shader loading without microphone/desktop access. Xcode package-plugin validation may require approval for MLX's CUDA build plugin (inactive on macOS); scripted builds can use `-skipPackagePluginValidation` after inspecting that pinned plugin.
- Download speech and cleanup models; record with both toggle and hold modes, view partial text and stop/cancel hints, disable popup, verify copy/paste and shared-history behavior. Exercise missing/disconnected microphone, cancellation during permission/model load/paste, and model idle unload. Verify application launch/focus and the momentary shortcut reference. These live behaviors are separate from fixture tests.
- With models unloaded, start dictation: show Preparing and the model being loaded, keep the microphone closed and timer hidden until every required local model is ready. Release a hold shortcut during preparation: recording must never start later. Disable cleanup and confirm no text model is prepared; required models must stay resident throughout recording.
- Pause speaking with a connected microphone: silence must not show "No microphone input". Stop audio-buffer delivery or disconnect the input and verify the warning appears after two seconds, then clears when buffers resume.
- Disconnect the saved microphone before starting dictation: recording must start on the macOS default and the popup must select System default. Switching inputs in the popup must preserve captured audio and save an explicit choice, including choosing the already-active System default. Automatic fallback alone must preserve the saved preference for reconnection.
- Switch Local/External in an audio rule's model picker, including an empty source and clicks beside the labels inside each tab. Installed choices must appear promptly without loading weights, with download sizes and Recommended labels. Delete a selected model and verify affected rules choose another compatible model; local rules stay local. Save an already-open editor and restart with an older missing-model selection: neither may restore the deleted selection, and unrelated draft edits must survive. Check Settings → Local models and copy an error or the complete log.
- Repeat model recovery after a download folder is changed or the selected download has already disappeared from disk. Deleting the last speech model must leave an editable rule with an explicit model-selection message; it must not start recording with a missing model.
- Window switcher: open several windows in one app plus another app, hold Command and cycle with Tab/Shift–Tab/arrows, then release to activate the exact selected window. Test Escape, Return, hovering/clicking a row, rapid press/release before discovery finishes, closing a target during discovery, hidden/minimized targets, and other Spaces/full-screen applications. Opening/cancelling the overlay must not activate Frog or change the source window.
- Disable window switching, quit Frog, revoke Accessibility, and enter shortcut-recording mode: interception must stop and the native shortcut must remain available. An enabled writing rule assigned Command–Tab must retain its shortcut and show the conflict in Windows. Permission/status polling must not redraw unchanged menus.
- Type continuously in a disposable text field with Frog running, including while its settings are open or busy. Input must remain smooth and ordinary keys must schedule no switcher UI work. Compare tagged synthetic input latency with Frog closed; a deliberately busy Frog UI thread must not delay delivery in another app. Verify background scans pause while typing and Command–Tab refreshes an aged inventory, including newly opened/closed windows. Repeat enable/disable and quit to check input-thread teardown.
- Enable history, process manually and by hotkey, relaunch, inspect/copy/delete/clear records. Disable recording during a request; its result must not be recorded. Verify configured bounds/expiry.
- Scroll History with many long transcripts: compact previews must stay responsive, while opening/copying/searching still uses complete text. The isolated native scroll regression measures UI/layout time separately from timer scheduling and uses synthetic history only.
- With History enabled, press Escape during recording, transcription and cleanup. The microphone/popup must stop immediately; one entry marked **Interrupted · Esc** must receive the full raw transcript in the background without copying, pasting or running cleanup. Open the entry while it transcribes and verify it updates in place. Start another recording during recovery; neither transcript may alter the other. Cancel buttons use **Interrupted**. Disabled History must not start recovery; deleting/clearing history or disabling it must cancel pending recovery and never restore removed entries. A failed recovery retains available text and shows its failure; old history still loads.
- Export a configuration, edit a rule and import it again. Verify the replacement summary, backup file, provider routing and shortcut registration. Invalid JSON/references/shortcuts leave current settings untouched. Exported JSON contains neither API keys nor text history. Re-enter keys for new/changed connections on import.
- Launch normally and at login: confirm the menu icon appears without a settings window or Dock icon. Open/close/reopen settings explicitly; closing must leave Frog running. Enable Start at Login for `/Applications/Frog.app`, inspect Login Items approval, log out/in and confirm the same quiet startup. Disable startup and confirm removal.
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

## Distribution

Developer ID signing/notarization requires the owner's Apple Developer credentials. Ad-hoc signing is suitable for local development, but is not notarization and does not establish that macOS will trust a downloaded release on another machine.
