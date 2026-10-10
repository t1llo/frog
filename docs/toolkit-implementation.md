# Configurable native toolkit

Frog's toolkit keeps native macOS interfaces and the existing writing, dictation,
local-model and connected-provider workflows. Each optional module owns its work:
disabling it removes its commands and navigation, closes its panels, and stops
its shortcuts, timers and observers. Its settings remain available in Features.

Mr. Usage is an optional integrated module. Lofitime and Pomodoro are excluded.

## Agreed completion scope

The selected scope is the Raycast-style toolkit: feature hub, global search,
windows, clipboard, local AI/dictation, Mr. Usage, snippets, notes, shelf,
calculations, saved scripts and quick actions.

- [x] Feature catalogue and backward-compatible settings
- [x] Native sidebar routing with individually enabled tools
- [x] Global command bar with application, window and Spotlight file search
- [x] Calculator, unit conversions and emoji search
- [x] Optional Mr. Usage: plan limits, resets, token charts, model costs and credits
- [x] Local Markdown notes, snippet variables and private document persistence
- [x] Shelf file/text/link drop, drag, copy and sharing
- [x] Saved scripts with bounded output and cancellation
- [x] Searchable rule, window-layout and quick actions
- [x] Native feature-disable, interaction and packaging verification

The existing window switcher, 23 window actions, 28 native Other shortcuts, 100-item memory-only clipboard
with formatted/plain-text paste, writing, dictation and model management remain
part of the integrated toolkit.

The October 10 iteration gives Mr. Usage a second menu-bar percentage/bar item and
popup. Collection follows feature enablement even with the dashboard closed;
disable/quit removes the item and stops collection. Display choices round-trip in
`preferences.toolkit.usage`, excluding credentials, readings and cooldowns.
Appearance now has ten themes and independent bounded popup transparency sharing
the app theme/accent. Command search reuses app/icon caches, recognizes Safari's
linked bundle, and includes Settings, Models, History and Features routes.

Stay awake remains available in the feature hub and menu-bar popup. Its session
is off by default, defaults to four hours, restores sleep on quit, and stops below
20% battery while unplugged.

## Native walkthrough

Verification uses a running app with isolated settings, synthetic clipboard and
document content, and private clones of downloaded models. Screenshots are kept
outside the public source tree. The final pass checks navigation, feature disable,
local inference, dictation, document editing, script execution and light/dark
surfaces before replacing the installed app.

The October 9 local pass verified real Qwen writing, Parakeet transcription of
synthetic speech, command-bar calculations/conversions and note navigation,
clipboard copy into the shelf, note persistence, scripts, and the then-current
usage visibility and enable/disable behavior. That lifecycle was superseded on
October 10.
For the October 9 build, checks passed: 280 tests with one additional
WindowServer-dependent test skipped, Xcode Debug build, signed arm64/x86_64 bundle,
and isolated menu-bar-only startup. The installed local build retains version
1.0.13 with a new build number; these changes have not been published as a release.

The October 10 feedback walkthrough verified the second Usage item, compact popup,
provider/period menus, continued collection with the main window closed, and
disable/re-enable teardown. Native screenshots covered light, dark and Nord themes.
Safari appeared with its app icon; calculator and Settings commands resolved.
Command opening measured 51 ms cold and 9 ms warm; clipboard opening measured
45 ms cold and 4 ms warm. These measure the presentation call, not full search completion.
Bundled Parakeet preparation measured 7.97 s cold, under 1 ms while resident and
363 ms after unloading. Record/Stop transcribed the synthetic speech correctly.
The integrated suite passed 287 tests (66 core, 9 usage, 212 app), with no failures.
After removing the walkthrough bridge, focused Usage checks, signed universal
packaging and isolated accessory startup passed. Local build `20261010065719`
(version 1.0.13) replaced the installed app with unchanged configuration and downloaded
model inventory. The executable and signing team matched the verified bundle.

## Separate popup defect

The reported intermittent oversized menu popup still needs a failing live
geometry capture. Repeated native probes and the installed geometry-only
diagnostic have measured normal sizing; no popup-sizing fix is claimed.

## Data and execution

Portable configuration contains feature choices and settings. Credentials stay
in Keychain or with the tool that owns them. Clipboard contents, personal notes,
usage records, indexes and captured media are not configuration-export payloads.
New optional collectors and system integrations start only when enabled.
Provider polling retains rate limits/backoff and does not refresh another tool's
OAuth tokens. Tests use isolated fixtures instead of a user's real accounts.
