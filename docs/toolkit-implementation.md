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
- [x] Saved scripts with bounded output and cancellation; output appears while a script runs and stays after Stop or the time limit
- [x] Searchable rule, window-layout and quick actions
- [x] Native feature-disable, interaction and packaging verification

The existing window switcher, 23 window actions, 28 native Other shortcuts, 100-item memory-only clipboard
with formatted/plain-text paste, writing, dictation and model management remain
part of the integrated toolkit.

The October 10 iteration gives Mr. Usage a second menu-bar percentage/bar item and
popup. Collection follows feature enablement even with the dashboard closed;
disable/quit removes the item and stops collection. Display choices round-trip in
`preferences.toolkit.usage`, excluding credentials, readings and cooldowns.
Appearance then had ten themes (eleven since the default `minimal`) and independent
bounded popup transparency sharing the app theme/accent. Command search reuses
app/icon caches, recognizes Safari's linked bundle, and includes Settings, Models,
History and Features routes.

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

## Command bar and clipboard navigation

The command bar opens on shortcut press, reuses normalized application records and
deduplicates with a set. Search uses stable rank buckets instead of sorting the whole
catalogue. Applications are what a search is usually for: an app whose name matches
ranks one level higher (a name containing the query ties with other titles that start
with it) and leads its level, behind only recently chosen results; files come last.
An application is listed under the name Finder shows and is also found under its bundle
names and its file name, so "Code" still finds Visual Studio Code, and under the last
part of its bundle identifier. "Open" or "launch" before its name still finds it; the
word App that every application row shows is not searched, so two of its letters do not
list every application.
File lookup remains asynchronous and debounced. Files whose names begin with the typed
text are asked of Spotlight by themselves and listed ahead of names that only contain
it; two letters find only the former. A lookup stops gathering once it has found about
a thousand files, far more than are listed. The bar opens in the middle of the
display the pointer is on. Drag its top grip or footer to move it; that position
survives reopening in the same session, until the bar is centred again or its display
is no longer available.

Rows beyond the bar's own (calculations, emoji and what later tools add) come from row
providers (`CommandBarRowProviding` in `CommandBarRows.swift`), asked in the order of the
bar's provider list. Catalogue rows are built once per opening and ranked with the other
records; rows for the typed text are rebuilt on every change, `.leading` ones above the
ranked results and the others after the file results, and are never remembered as recent
choices. A row without a primary action is informational: choosing it does nothing and the
bar stays open. A primary action with `confirm` text asks first: the first Return shows that
text in place of the subtitle, a second Return on the same row within three seconds runs it,
and moving the selection, typing or waiting restores the row.

A System Settings pane appears once, with the System Settings icon and that name beside
it. The shortcut actions that open the same panes stay out of the results; the other
shortcut actions say where they act: Finder, Mac or Current app.

First-run setup and Command bar settings share a Spotlight replacement walkthrough:
free ⌘Space in macOS Keyboard Shortcuts, explicitly assign it to Frog, then try it.
The setup never rewrites system shortcuts. Registration conflicts remain visible;
retrying the same shortcut retries registration after System Settings changes.

Clipboard is a settings page with the paste-picker shortcut. **Open clipboard history**
navigates to the single History page with **Clipboard** selected. That filter's clear
action only clears in-memory clips; saved text/audio history remains separate.

## Dynamic popup sizing

The later native reproduction found a 326-point MenuBarExtra window retaining its
initial height after a conditional row disappeared and Frog's content shrank to 252.
Removing fixedSize alone did not fix it. A non-interactive sizing background now
coalesces content changes and resizes the native window with its top edge anchored.
The same native reproduction then measured 252 for both host and content, removing
the translucent strips. The existing shared rounded blur mask remains in use.

## Floating panels

Every new Frog panel is a `FrogFloatingPanel`: a borderless, non-activating panel on
every Space that is shown with `orderFrontRegardless()`, so the frontmost app keeps its
focused field. Its SwiftUI content sits in a `FirstMouseHostingView`, which takes the
first click while another app stays active. A panel next to a selection converts the
Accessibility bounds with `AXGeometry.cocoaRect` and places itself with
`PanelPlacement`: on the display holding the selection, below it when it fits, else
above, else on the side with more room, kept inside the visible frame. Without a
selection it opens beside the pointer. When its content changes height it keeps the
edge next to the selection. `PanelFooter` shows the panel's name, what Return does and
**Actions ⌘K**; `FrogType` and the `FrogStyle` radii are the type and corner tokens new
views use.

Keys go through `PanelKeyMap`, one convention for every panel. Key codes are physical
positions, so the letters follow their QWERTY places on any layout. While an input
method is composing, every key goes to the text field.

| Key | Does |
| --- | --- |
| ↩, keypad Enter | Run the selected row's primary action |
| ⌘↩ | Run its secondary action |
| ⇧↩ | Run it as plain text where the row has that variant, else the primary action |
| ⌘K | Open or close the action panel |
| ↓, ⌃N / ↑, ⌃P | Move the selection |
| Esc | Close the action panel; else clear the query (panels that clear on Escape); else close |
| ⌘W | Close the panel |
| ⌘1 … ⌘9 | Run that action while the action panel is open |

Anything else, ⌘⇧↩ included, goes on to the text field.

## Data and execution

Portable configuration contains feature choices and settings. Credentials stay
in Keychain or with the tool that owns them. Clipboard contents, personal notes,
usage records, indexes and captured media are not configuration-export payloads.
New optional collectors and system integrations start only when enabled.
Provider polling retains rate limits/backoff and does not refresh another tool's
OAuth tokens. Tests use isolated fixtures instead of a user's real accounts.
