# Local activity statistics

Statistics is a Settings subpage for aggregate activity on this Mac. It has all-time,
7-day and 30-day views, recording count/time/words/weighted words-per-minute, rule
breakdowns and tool counts. A parent view hosts `StatisticsView(statistics:onBack:)`.

## Data contract

- `FrogCore.ActivityStatisticsSnapshot` is Codable and contains only a version,
  device-local recording switch, all-time counters and up to 365 Gregorian daily
  buckets. Bucket labels use the device's local civil date at completion. Recent
  periods include today. Traveling does not relabel existing buckets.
- `ActivityStatisticsPersistence` stores `statistics.json` in Application Support/Frog
  by default, or a supplied isolated directory. It has no dependency on preferences,
  transformation history, model configuration, exports, or Usage collection.
- No transcripts, rule names, paths, queries, app names, provider identities, tokens,
  individual event timestamps or event logs are retained. No network calls exist.
- Collection defaults to enabled for this explicitly requested local feature. Pausing
  prevents event writes and retains existing totals. The switch is persisted in this
  file, not portable configuration. Reset clears all counters and daily buckets while
  preserving the switch. Recovering an unreadable file by reset starts **paused**.
- Counters start with this implementation; existing history is never backfilled.
- Daily buckets older than 365 days are omitted on load and removed on the next
  statistics mutation. The file itself never exceeds 365 daily buckets. All-time
  totals remain. No active day produces an empty bucket.
- Private atomic writes (0600), bounded reads (1 MiB), symlink rejection and serialized
  read/modify/write operations protect this independent file. Corruption/unsupported
  versions prevent recording until explicitly reset; ordinary writes preserve them.
  Errors are exposed on the page and must never fail an otherwise successful action.
- WPM is total words / total microphone seconds × 60, not an average of per-recording
  rates. Foundation's Unicode word segmentation ignores punctuation and emoji alone.
  Word segmentation is an estimate, including for languages without spaces.

## Parent integration API

The service is `@MainActor final class ActivityStatisticsStore: ObservableObject`.
It loads during initialization. There is no asynchronous load/flush requirement;
each low-frequency completion persists one small transaction synchronously.

```swift
// AppModel stored property:
let statistics: ActivityStatisticsStore

// Inside AppModel.init, after resolving dataDirectory/FROG_DATA_DIRECTORY:
self.statistics = ActivityStatisticsStore(directory: dataDirectory)

// In Settings, with a parent-owned subpage or sheet state:
StatisticsView(statistics: model.statistics, onBack: { showingStatistics = false })
// Omit onBack when a sheet supplies its own dismissal control.

// Successful completion hooks (exact API):
statistics.recordRuleExecution(kind: .local) // .remote, .cli, .dictation,
                                            // .application, .window, .system
statistics.recordDictation(recordingSeconds: microphoneSeconds, text: rawTranscript)
statistics.recordToolUse(.clipboardPaste)
// Other tool kinds: .applicationCommand, .windowCommand, .systemCommand,
// .commandSelection, .scriptRun, .snippetCopy

statistics.setRecordingEnabled(false)
statistics.reset()
statistics.reload()
```

Published read-only state: `snapshot`, `issue: String?`, `loaded: Bool`.
The page observes the service directly; `AppModel.objectWillChange` forwarding is
unnecessary for the page. If a Settings summary reads totals, observe the service
there too. Tests constructing AppModel must pass their isolated `dataDirectory`.

Core API, when needed outside the UI:

```swift
let store = ActivityStatisticsPersistence(directory: isolatedDirectory)
let state = try store.record(.dictation(recordingSeconds: 30, words: 60))
let recent = state.totals(lastDays: 7)
let count = state.allTime.ruleRuns(.local)
let pastes = state.allTime.toolUses(.clipboardPaste)
```

## Completion hook map

AppModel owns the store and completion wiring. The Statistics route is a Settings
subpage. The page observes its store directly.

1. **Text rules — `AppModel.begin(...)`:** record once after valid nonempty output and
   successful manual delivery or selection replacement, outside the history-enabled
   block. A failed replacement's fallback clipboard result must not count as a
   successful replacement. Keep cancellation checks before counting. Classify built-in
   models (`provider.id == Self.localProviderID`) and `provider.kind.isLocal` as `.local`;
   HTTP/cloud providers as `.remote`; use `.cli` when an actual CLI text backend is used.
   Connection tests/model discovery/previews must not increment rules.
2. **Dictation — `DictationController.onSuccessfulDelivery`:** count after current-token,
   cancellation and delivery success checks, never `onTranscript` (fires before delivery),
   preview, recovery, `onCopy`, or start. Also count `.dictation` rule execution once.
   Pass the **raw** transcript for dictated-word counts rather than cleanup-expanded text.
   The callback carries fractional monotonic capture-start/stop seconds, frozen at Stop.
   It excludes preparation, decoding, cleanup and insertion waits. The separate
   `onFinish` remains fallback-aware and is not used for counting. Intentional copy-only
   delivery counts; failed requested paste does not. Cancelled/recovered
   recordings and failed cleanup/rule completions must not increment success counters.
3. **Application rules — `AppModel.launchApplication`:** after `ApplicationLauncher.launch`
   succeeds and cancellation checks, record `.application`. Application launches from
   `CommandBar.addApplications` count `.applicationCommand` instead.
4. **Window rules — `AppModel.manageWindow`:** after `windowManager.perform` succeeds,
   record `.window` for saved rules, otherwise `.windowCommand` for direct actions.
   Command-bar windows count only after verified foreground activation. Window-switcher
   navigation is not counted.
5. **System rules — `AppModel.performSystemAction`:** after `SystemActionController.perform`
   succeeds, record `.system` for saved rules, otherwise `.systemCommand` for direct actions.
6. **Clipboard — `ClipboardHistoryController.choose`:** add a success callback immediately
   after `ClipboardHistoryDelivery.paste` succeeds. Wire it to `.clipboardPaste` in
   AppModel. Also hook the command-bar clipboard delivery branch. Copy-only actions,
   history polling, rejected targets and failed/cancelled delivery are not pastes.
7. **Scripts — `ScriptRunner.run`:** after the existing current-generation and cancellation
   guard, invoke a success callback only when `result.status == 0`; wire `.scriptRun`.
   Starting a script from the command bar is not script completion.
8. **Snippets — `UtilityDocumentsView.copy` and command-bar snippet delivery:** count
   `.snippetCopy` only after the pasteboard write returns true. No snippet text reaches
   the statistics API. Avoid counting a failed write from the existing ignored Bool.
9. **Command bar — accepted selections:** `.commandSelection` counts accepted dispatch,
   not successful completion of an asynchronous rule or script. The UI calls this
   “Command bar selections.” It excludes queries, opening, cancellations and immediate
   dispatch failures. Eventual rule/script success uses its own hook. There is no
   combined grand total across these different categories.

## Verification

Targeted tests live in `ActivityStatisticsTests.swift` and
`ActivityStatisticsStoreTests.swift`. They exercise private round trips, concurrent
writers, Unicode counting, duration validation, time-zone/DST boundaries, recent
periods, 365-day retention, opt-out across relaunch, reset, corrupt/future data and
symlinks using temporary directories only.

Run with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ActivityStatistics
```

The Xcode project uses synchronized source groups. Integrated tests additionally
exercise successful delivery, failed insertion and cancellation through AppModel;
fixture CLI processes cover installed-tool dispatch without Frog credentials.

Lane verification: all 12 persistence/service tests passed both in an isolated package
and in the full repository targeted run above, including app/view compilation. Logs:
`frog-statistics-tests.log` and `frog-statistics-isolated-tests.log` in the harness's
approved temporary directory. No real user data was read or modified by these tests.
