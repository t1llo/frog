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

## Learned command bar choices

`CommandChoices` (FrogCore) remembers which row was picked for what was typed; it is
the model behind the Command bar's **Learn from your choices**. The typed text is stored
as its search key (`CommandSearch.searchKey`: case and diacritics folded) with runs of
whitespace collapsed, in canonical composed form, cut to its first 32 characters. Rows
whose ids start with `clipboard:`, `window:` or `calculation:`, and ids over 1,024 UTF-8
bytes, are never recorded.

- A strength is stored as of its last pick and read decayed:
  `decayed = strength × 0.5 ^ (max(0, now − last) / 14 days)`.
- A pick sets the pair (text, row) to `min(decayed + 1, 5)` and every other pair with the
  same text to `decayed × 0.5`, all with `last = now`. Empty text creates no pair. The
  row's own item becomes `min(decayed + 1, 10)`.
- Entries whose decayed strength is below 0.1 are dropped, so a single pick lasts about
  seven weeks; at most the strongest 500 pairs and 300 items are kept.
- For typed text `q`, `S(id)` is the largest decayed strength of a pair whose text starts
  with `q` (compared on UTF-8 bytes), counted whole when the text equals `q` and half when
  it is longer. Rows with `S > 0` lead, strongest first, then the latest pick.
  The strongest is **latched** when `S ≥ 2` and strictly above the next row's.
- `CommandSearch.results(…, latched:)` puts a latched row that the typed text finds above
  every bucket, in the same single pass; the other learned rows only lead their bucket
  through `preferred`.

What ranking guarantees:

1. Apart from the one latched row, no row passes a better match; learning only reorders
   rows inside a bucket.
2. At most one row leaves its bucket, so an exact title or alias match, an exact
   application included, loses at most one place.
3. A latched row was picked at least twice for this text, or about four times for a
   longer text starting with it, and more than any other row.
4. Two picks of another row for the same text move the latch: with Calculator at 5 for
   "ca", one pick of Calendar gives Calendar 1 and Calculator 2.5 (the latch stays), a
   second gives 2 and 1.25 (it moves to Calendar). Alternating picks never latch.
5. A row that the typed text does not find is never listed.

`CommandChoicesPersistence` keeps them in `command-choices.json` in Frog's data folder
(`~/Library/Application Support/Frog/`), never in the configuration: a 0600 file in a
0700 folder, written through a temporary file, read with a 1 MB limit and rewritten below
512 KB by dropping the weakest pairs 50 at a time. Each change reads, applies and writes
under one lock, so two copies of Frog merge their picks. A broken or newer file is left
as it is, and only forgetting the learned choices deletes it.

`CommandChoiceStore` (FrogApp) reads the file only while **Learn from your choices** and
the Command bar are both on (`command-bar.learn-choices`). A pick that completed, a copy
with ⌘↩ included, changes the memory and the index at once and is saved on a serial
utility queue; forgetting goes through the same queue, so a pick still being saved cannot
bring the file back. Turning the switch or the Command bar off, from Settings or from the
configuration file, and **Forget learned choices…** delete the file; quitting keeps it. A
file that cannot be read or saved pauses learning, and the bar ranks with this session's
picks only, until the choices are forgotten. After a load and after each pick, the 30
strongest learned files are checked on a background task and listed before Spotlight
answers; a learned file that fails to open is forgotten. The index is rebuilt when the bar
opens if it is more than an hour old, never per keystroke.

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

## Answers

An answer rule sends its instructions and one conversation, which `AnswerPrompt` in
FrogCore builds without windows, network or models. The first message is:

````
App: Safari
Reply language: German

Selected text:
```
river bank
```

Surrounding text:
```
We had a picnic on the river bank before the storm.
```
````

A line or block without a value is left out, and so is surrounding text equal to the
selection. The fence is one backtick longer than the longest backtick run in the texts,
at least three. The reply language is the Mac's first preferred language named in
English, else English. The page address or document path stays with History and notes
and is never part of a message. Each follow-up adds the previous answer and the next
question, so roles alternate from user to user; coding tools receive the same
conversation as one transcript.

A selection may have up to 12,000 characters for Frog's own models, Ollama, LM Studio
and OpenAI-compatible servers, whose small context windows truncate silently, and up to
100,000 for OpenAI, Claude, Gemini and the coding tools. A longer one is refused, not
cut. An answer takes at most 10 follow-ups of up to 2,000 characters each; when the
messages and instructions would pass 200,000 characters, the surrounding text is dropped
first, and the follow-up is refused if that is not enough. `SurroundingText` sends the
enclosing paragraph, else the line, else the nearest sentences, up to 1,000 characters
with "…" where text was left out. `ReasoningFilter` hides one leading
`<think>…</think>` block; an answer that is only reasoning ends with an error.

### Answer engine

`AnswerController` runs one answer and its follow-ups at a time; starting another cancels
the running stream and replaces the session. Before anything is sent it checks, in order,
that the selection is not empty, that the rule's model resolves, that the selection fits
the model's limit and that the instructions expand. A failure opens the panel with the
message, offers Edit rule for a model or rule problem, and goes to the log. An answer
rule never inherits the older default model or provider: without a model of its own it
asks for one.

`AnswerStreams` picks the backend. Frog's own models stream through `LocalModels.stream`,
which waits for running work like Writing does and keeps idle unload, residency and
memory pressure; an answer may use up to 2,048 new tokens, and text that reaches the
limit is kept and marked rather than refused. HTTP providers stream through
`LLMClient.stream`. A coding tool cannot stream: it receives the conversation as one
transcript and answers in one piece, within 180 seconds.

Each turn's text passes a fresh `ReasoningFilter` before it reaches the session. The
panel, behind the `AnswerPresenting` protocol, is updated at most every 50 ms while text
streams, and at once when the phase changes or a turn ends. A turn with no visible text
fails. The first completed turn counts one rule run (local, coding tool or remote, as
Writing counts) and is recorded; later turns update that record until an update is
refused. Stop keeps the text so far and records nothing; Retry sends the same messages
again; a provider error is shown with Retry and logged, and cancelling is not an error.
Answers never use Writing's `isProcessing`, its processing pill or its outcome, so a
Writing rule can run while an answer is open.

### Selection capture for answers

A captured selection (`CapturedTextSelection`) offers four optional values besides its
text: `anchor`, the selection's rectangle in Cocoa screen coordinates; `context`, the
sentence or paragraph around it, at most 1,000 characters; `applicationName`; and
`source`, the document or page address. They are protocol requirements with nil
defaults, so a capture seen as `any CapturedTextSelection` answers with its own values.
The compatibility Copy keeps the defaults, and its answer opens at the pointer without
context.

A selection read through Accessibility computes each value on first use only. Writing
rules never ask, so they make no extra reads. The anchor is the selected range's
bounds, or the last character's when the selection is taller than half of its screen.
The context comes from the field's value already read at capture when it has at most
200,000 UTF-16 units; otherwise Frog reads the character count and only 1,500 units on
either side of the selection, and never more than 200,000 characters. The source is the
focused window's document, else the address of the web area that holds the selection,
for `http`, `https` and `file` only, without user, password, query or fragment. It stays
with History and notes and is never sent to a model. Every element these reads touch has
the same one-second messaging timeout as the capture itself.

### Answer panel

`AnswerPanelController` is the app's `AnswerPresenting`: a 400-point `FrogFloatingPanel`
that may become key, so the follow-up field takes typing, but never activates Frog. It
places itself with `PanelPlacement` from the selection's anchor, else the pointer, and
grows with its content up to 560 points or 60 % of the display's visible height,
whichever is lower; beyond that the answer scrolls. SwiftUI reports the header, answer and
footer heights, and the controller resizes keeping the edge next to the selection. A
panel that was dragged or pinned keeps its top edge instead. A model built without
shortcuts, as in tests, gets `SilentAnswerPresenter` and never opens a window.

The monitors exist only while the panel is open and are removed when it closes: a local
key monitor for the panel's own keys, a global key monitor that reads the key code and
acts only on Escape, a global monitor for left and right clicks, and a workspace observer
for app activation. Events from before the panel opened are ignored. `AnswerPanelDismissal`
in FrogCore decides, without windows:

| Event | Unpinned | Pinned |
| --- | --- | --- |
| Close button, Escape or ⌘W in the panel | Closes | Closes |
| Escape in another app | Closes | Stays |
| Click outside the panel | Closes | Stays |
| Another app becomes active | Closes | Stays |
| The app the text came from becomes active again | Stays | Stays |

In the panel ⌘↩ copies the latest answer and ⌘. stops it; other keys go to the follow-up
field, and every key does while an input method is composing. Edit rule opens the Explain
page, which activates Frog and so closes an unpinned panel. The panel is one
accessibility group named "Explain answer" and announces "Answer ready" when an answer
finishes.

`AppModel.processSelection` sends a rule with `textOutput: "panel"` to `AnswerController`
only while `feature.explain` is on, and otherwise does nothing; such a rule never goes
through Writing. The capture runs as for Writing, the surrounding text is dropped when
`explain.context` is off, and turning Explain off cancels a capture in flight and closes
the answer.

## Data and execution

Portable configuration contains feature choices and settings. Credentials stay
in Keychain or with the tool that owns them. Clipboard contents, personal notes,
usage records, indexes and captured media are not configuration-export payloads.
New optional collectors and system integrations start only when enabled.
Provider polling retains rate limits/backoff and does not refresh another tool's
OAuth tokens. Tests use isolated fixtures instead of a user's real accounts.
