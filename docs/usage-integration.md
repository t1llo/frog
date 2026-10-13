# Embedded Mr. Usage

`native/FrogUsage` is a separate Swift module derived from the user-owned
[Mr. Usage repository](https://github.com/t1llo/mr-usage), source commit
`698f8071ef45fe295d7d871e58a1c032449d0c8a`.

Frog owns the app lifecycle, menu bar, updater, feature settings and dashboard.
`UsageDashboardModel` construction is inert. Enabling the feature starts collection
and installs a second status item through `UsageStatusItemController`, using the
standalone-style two-window percentage/bar readout and a shared-model popup.
Collection continues with the main dashboard hidden or closed. Disable and quit
remove the item, close its popup and stop collection. This supersedes the earlier
visible-page-only lifecycle. Generation checks reject late replies; cancellation
reaches off-main readers and aggregation as well as URL requests.

The extracted parsers preserve message deduplication, token pricing, complete-day
account reconciliation, last-good limits and request cooldowns. Credentials stay
with their originating tools, and OAuth refresh remains their responsibility; since
2026-10-13 Frog may start Claude Code so that it renews its own login (see below).
Display choices (`provider`, `range`, `metric`, `loginSource`) round-trip
through `preferences.toolkit.usage` and are shared by the popup and dashboard.
The legacy `allDevices` field round-trips for compatibility but no longer selects a
source: OpenAI always combines available account activity and local tool logs.
Credentials, account details, readings and polling gates are not exported.
Frog uses the separate local `xyz.beffa.frog.usage` defaults domain for cached
metadata, cooldowns and a local copy of display choices. Usage endpoints receive
no transcripts; OAuth renewal remains with the originating tools.
Fixture roots and defaults suites isolate tests from real tool logs and accounts.

The compact dashboard and popup share plan meters, remaining percentages,
reset countdowns and an elapsed-window tick. Plan readings identify their account
or local-log source and age. Token history uses a quieter bar chart and relative
model totals; account-wide token splits and API cost remain labeled estimates.
[Vorssaint source research](research/vorssaint-usage-reference.md) informed this
presentation; Frog retains its existing Mr. Usage collectors and reset timestamps.

The reference toolkit's implementation source was not imported. Frog's catalogue,
command bar, document tools, script runner and interface are independently written.

## Collector audit — October 10

### OpenCode V2 and combined OpenAI activity

The current OpenCode storage contract was checked against public source revision
[`055d95bb7e278c94baf06235a52cac79dd13ba67`](https://github.com/anomalyco/opencode/tree/055d95bb7e278c94baf06235a52cac79dd13ba67):
[storage tables](https://github.com/anomalyco/opencode/blob/055d95bb7e278c94baf06235a52cac79dd13ba67/packages/core/src/session/sql.ts),
[assistant schema](https://github.com/anomalyco/opencode/blob/055d95bb7e278c94baf06235a52cac79dd13ba67/packages/schema/src/session-message.ts),
[model reference](https://github.com/anomalyco/opencode/blob/055d95bb7e278c94baf06235a52cac79dd13ba67/packages/schema/src/model.ts),
and [token mapping](https://github.com/anomalyco/opencode/blob/055d95bb7e278c94baf06235a52cac79dd13ba67/packages/core/src/session/runner/publish-llm-event.ts).

V2 stores assistant counters in `session_message`, with a `type` column and nested
`model.providerID` / `model.id` fields. The earlier reader queried only V1's `message`
table, silently missing current activity in databases retaining both generations.
The reader now discovers and unions both tables when present, projecting only model,
time and token counters. It keeps fork-copy deduplication and DB/WAL invalidation.
Visible output and reasoning are added once; input/cache counters remain separate.

A generated mixed-format fixture reproduced 10 tokens instead of 205 before the fix.
The corrected integration fixture includes Codex too and reports the combined 220,
with separate OpenCode and Codex source totals. V2-only storage, malformed rows, user
rows, fork copies and mutable WAL updates are covered. All **22 Usage tests** pass.

The dashboard and popup no longer offer **This Mac / All devices**. OpenAI automatically
reconciles reported account days with local Codex/OpenCode activity on unreported days,
using the existing no-double-counting rule. Account reports remain daily estimates,
so OpenAI offers 7d/30d ranges. With no account report, all available local activity
is shown. Plan limits still come from the account endpoint or labeled Codex snapshots;
token totals do not invent a plan percentage. No personal logs or credentials were
read to diagnose this change.

Independent fixes, checked using generated fixtures against the actual Frog readers:

- **Codex:** accept current `token_usage_record.payload.session_id`, legacy
  `thread_id`, and omitted owner/response IDs. Explicit conflicting owners and copied
  parent records are excluded. Streaming/resumed duplicates retain maximum counters;
  legacy totals are keyed by session as well as timestamp. Explicit non-OpenAI
  `model_provider` values are excluded from OpenAI token/plan totals; omitted provider
  metadata retains legacy compatibility. Cache reads/writes cannot exceed reported
  input; negative, boolean, fractional and out-of-range counts are rejected.
- **OpenCode:** malformed JSON rows cannot abort the whole selection. Missing
  embedded creation timestamps use the database's `time_created` column. Existing
  provider filtering, channel database discovery, mutable-row rereads and fork-copy
  deduplication remain in place; reads still run on the reader actor.
- **Quota freshness:** an expired Codex window is omitted, not displayed as a made-up
  zero. A wholly expired snapshot without credits reports current limits unknown.
  Original readings and timestamps remain available internally.

`UsageChart.sources: [UsageSourceTotal]` is an additive display API. Each entry has
`name`, `value`, and `id`; values use the selected metric and period and sum to the
chart total. OpenCode is a source within Claude/OpenAI, not a new quota provider.
Account-wide mode reports reconciled source totals: server-covered UTC days replace
their local sources, with local records filling unreported days. A zero source value
can coexist with `unpricedModels`; it must not be presented as a confirmed free bill.
The parent UI may render these entries with the existing `format(_:metric:)` helper.
No exported preference fields changed.

Claude Desktop's `plan-usage-history.json` was first evaluated and left out; it is now
a second source (see "Claude app readings" below), labeled as such, with account
matching for anything borrowed from the authenticated reading.

Verification: an isolated package linking only `native/FrogUsage` and its tests ran
under Xcode's toolchain: **14 tests passed**, including lifecycle, late-reply rejection,
portable preferences, parsing and account reconciliation. The initial new fixtures
failed on modern Codex records, malformed SQLite rows and expired windows before the
fixes. No real logs, credentials, authenticated requests or native app build were used.
Source references and comparison details are in the linked research note.

## Standalone parity follow-up — October 10

Compared the local `t1llo/mr-usage` checkout at the source commit above with Frog's
display bridge, especially `Sources/TokensView.swift` and `Sources/Views.swift`.
The standalone source already collected the missing statistics: the integration
had omitted their public display fields and views. The pinned Vorssaint reference
also informed local refresh and changed-database handling; its code/assets were not
copied. This comparison is source evidence, not a live account comparison.

Implemented:

- **Token information:** selected-period total tokens and all five metric totals
  (API equivalent, uncached input, output, cache write/read) are visible and clickable
  in the dashboard. The compact popup shows the selected metric and total tokens.
  Zero output or an unpriced model no longer means
  “No token activity.” Unpriced cost still carries an explicit missing-price note.
- **Lifetime and history:** expandable Claude Code `/stats` lifetime details;
  OpenAI lifetime/peak/streak/chat/reasoning details; five recent plan windows with
  per-model percentages and report age. Lifetime counts stay separate from charts.
- **Plans:** OpenAI plan names, Claude plan names when the selected Claude Code
  profile provides organization/tier metadata, dashboard pace labels, and all quota
  windows in the popup. The status tooltip includes every window, reset times and source
  status, while its narrow glyph keeps the first two meters.
- **Source/range accuracy:** account mode permits only daily 7d/30d periods, using
  UTC chart dates. Missing account activity is labeled as a local-log fallback.
  Local logs can span accounts and do not pretend to match the selected quota login.
  Existing saved provider/source/metric choices are retained.
- **Profiles:** the dashboard can select a Claude Code configuration folder, like
  standalone. This local-only path selects its quota login and lifetime cache and
  adds its project transcripts. Standard discovery also includes `.config/claude`;
  canonical duplicates are removed. The folder is not exported in preferences.
- **Refresh:** explicit refresh immediately rescans local counters, coalescing a
  request made during an existing scan. Visible dashboards/popups refresh local
  counters every ten seconds; hidden collection keeps its one-minute cadence.
  Anthropic/OpenAI remote request gates and credential ownership are unchanged.
- **OpenCode reliability:** unchanged database/WAL metadata reuse parsed counters.
  Changes reread the bounded horizon, preserving mutable-row/revert/fork semantics.
  Temporary query failures retain the last readable counters with a visible warning;
  successful recovery clears it. Removed databases remove their counters.
- **Presentation:** superseded by "Popup and readout" below. Popup content is created
  when opened; enabled background collection does not need a hosted popup view.
- **Interaction follow-up:** weekly bars include On pace / Ahead of pace / Under pace
  (or Limit reached), based on elapsed time with a ten-percentage-point tolerance.
  Unknown/expired windows do not claim a pace. A one-limit layout uses its spare room
  for Input / Cached input / Output totals. The normal summary fits without scrolling;
  shorter displays retain a scrolling fallback. Outside mouse clicks and application
  deactivation dismiss the popup; inside interactions remain active.
- **Provider switching:** selecting a display provider no longer reconfigures hotkeys,
  reloads history or restarts toolkit services. Configuration serialization runs on
  an ordered background queue. Other configuration writes, reload/import and shutdown
  drain it first. Failed writes restore the last saved display choice and report the
  error; optimistic store checks continue to preserve external configuration edits.

Synthetic verification uses `UsageParityTests.swift` alongside the existing parser
and lifecycle suites. The initial two regression tests failed with three assertions:
explicit Refresh showed `0` instead of a newly written `42`, and account mode retained
`24h` plus the hourly option. Both passed after the fixes. Additional fixtures cover
lifetime separation, account/history units, malformed account fields, profile
discovery/export isolation, WAL edits, temporary schema failure, recovery and deletion.

Evidence under the approved temporary directory (`…/T/opencode/`):

- `frog-usage-parity-red.log`: the original red regressions.
- `frog-usage-parity-green.log`: isolated FrogUsage suite, **21 tests passed**.
- `frog-usage-parity-app-build.log`: integrated native build passes, including the
  usage SwiftUI view (the interim type-check failure was resolved).
- `frog-usage-parity-integrated-tests.log`: production suite, **379 tests passed**
  (21 usage + 86 core + 272 app), zero test failures.
- `frog-usage-parity-visual/`: synthetic native light/dark dashboard/popup captures,
  including scrolled metric/lifetime sections. Capture used only owned NSViews, not
  the desktop. Scratch visual test is excluded from production sources/tests.

Still unverified: real account responses and comparison against the user's running
standalone app. Claude Desktop-only activity/reset estimation, Copilot collection,
Codex app-server banked-reset credits and Keychain-only Codex authentication are not
implemented here. The existing collectors read tool-owned saved access tokens and
never renew them. Collector verification used no private account/log reads,
authenticated requests or permission grants. See [verification](verification.md)
for the integrated build and installation evidence.

## Claude app readings (2026-10-11)

Someone who only uses the Claude desktop app has no current Claude Code login: the app
hands its sessions a token directly, so the Keychain item Frog reads is never renewed
and every refresh fails. Frog still never renews or consumes another tool's tokens.

- **Source:** `native/FrogUsage/ClaudeDesktopUsage.swift` reads
  `~/Library/Application Support/Claude/plan-usage-history.json` (versions 1 and 2, at
  most 4 MiB): the newest sample's five-hour, seven-day, Sonnet and Opus percentages.
  The Claude app writes it every few minutes while its menu-bar icon is on. Reading it
  needs no login and makes no request. Unknown versions and fields are skipped. The
  reader was written for Frog; no code was taken from other trackers.
- **Selection:** login source `Claude Desktop` uses only this file and never reads a
  login. `Automatic` shows the newer of the authenticated reading and the saved one.
  The popup footer and dashboard name the source ("Claude app" / "Anthropic account").
- **Renewal times:** the file has none. They are borrowed from the last authenticated
  reading only when it belongs to the same organization and that window has not
  renewed; otherwise they are inferred only where two close samples bracket the start
  of a session (30 minutes) or a weekly drop (one hour). Without either, the bar shows
  no renewal time and no pace.
- **Staleness:** a saved reading, from either source, stays on display until its window
  renews, for at most 24 hours, with its age beside it ("Updated 10h ago"). This
  replaces the one-hour cutoff that turned the popup into "Plan limits unavailable".
  A Claude-app reading older than 30 minutes carries a warning (wording: see the
  2026-10-13 section). Renewed windows are unknown, never zero.
- **How often the Claude app saves:** only while its own usage display is running,
  which nothing outside the app can keep going; the file can stay untouched for days
  while the app is in daily use. It is a fallback, not a dependable source.
- **Session row:** a Claude session that renewed after the last reading keeps its row,
  marked "No reading since it renewed", so the week is never shown on its own.
- **Plan badge:** the cached Claude Code profile's plan is attached to a Claude-app
  reading only when both name the same organization.

## Popup and readout (2026-10-11)

- The popup is a borderless panel styled like Frog's own menu-bar popup (same 292-pt
  width, 42-pt header, panel surface, row and footer metrics) instead of an arrowed
  popover, opening left-aligned beneath its item. Its height follows its content.
- Header: title, the Claude/OpenAI switch and Refresh, both in the bordered compact
  control style. Plan limits (up to four) each show used, left, pace and renewal.
  The estimate is labeled "API estimate"; whole-dollar axis labels drop their cents.
  Open dashboard is a menu row; the footer shows the reading's age and source.
- Opening either popup posts `frogMenuPopupWillOpen`; the other one closes.
- Without a plan reading the menu-bar item shows the selected period's API estimate
  ("7d $185") rather than only the provider name; a reading that could not be
  refreshed is drawn dimmed.
- Limit bars and pace labels use the theme's status tones: `good` under pace,
  `warning` ahead of pace, `critical` from 95 % used; on pace keeps the accent. The
  System monitor uses the same tones for load, disk and battery. Each built-in theme
  defines them and `palette.light`/`palette.dark` can override them.
- Frog's Stay awake row was 18 pt wider than the popup and pushed its content off
  centre; the row now fits, so both popups share the same insets.

## Claude Code login renewal and sign-in (2026-10-13)

Report: limits a day old and the menu bar showing the API estimate instead of what is
left. Cause on that Mac: login source `Claude Desktop` (never reads a login), a Claude
app file last written three days earlier, so its reading aged out after 24 hours, and
a Claude Code login that had expired.

- **Renewal stays with Claude Code.** Frog still never reads, sends or stores a
  refresh token. When Claude Code's saved login has no current access token but can
  still be renewed (`claudeCodeLoginLapsed`, which checks only that a refresh token is
  present) and the login source is Automatic or Claude Code, Frog starts Claude Code
  once (`ClaudeCodeCLI.renewLogin`):
  `claude -p "OK" --model haiku --tools "" --no-session-persistence --strict-mcp-config
  --safe-mode --system-prompt "Reply with OK." --output-format json`.
  Claude Code renews its own login on the way and Frog reads the new access token.
  **This sends one very small Haiku request on the user's plan**, and only when the
  login has run out. OpenCode and Pi logins are never renewed this way.
- **How it is run:** the executable is looked up in `~/.local/bin`, `~/.claude/local`,
  `/opt/homebrew/bin` and `/usr/local/bin`, then on `PATH`. The environment is reduced
  to home, user, locale, temporary folder, proxy and certificate variables with `PATH`
  set to the system directories; `CLAUDE_CONFIG_DIR` is passed only for a non-default
  profile. Working directory is the temporary folder. No tools, no MCP servers, no
  saved session, 90-second limit; only the exit status is used.
- **Gate** (`ClaudePollingState.nextRenewalAt`/`renewalInterval`, saved with the other
  gates; state from earlier versions still loads): at most one attempt per 30 minutes;
  a failed attempt waits one hour, then two, up to eight; "nothing to renew" or "no
  Claude Code" is looked at again after five minutes because it costs nothing. A
  successful limits read clears it.
- **Sign in:** when no current reading can be had without a login
  (`Store.needsClaudeCodeLogin`), the popup shows a "Sign in to Claude Code…" row and
  the dashboard a button. The action first checks whether a login is usable or can be
  renewed, and then opens nothing. Otherwise it switches a `Claude Desktop` source to
  Automatic and opens Terminal with `claude auth login` through a `.terminal` launcher
  in a 0700 temporary folder (`ClaudeSignIn`); without Claude Code or Terminal it opens
  claude.com/claude-code. For ten minutes afterwards each 15-second tick looks for the
  new login. That is a local Keychain read: no renewal run and no request until a
  login exists. A check that finds no login is repeated after one minute instead of
  waiting out the request cadence, because nothing was sent.
- **Status texts** point to signing in to Claude Code instead of the Claude app's
  menu-bar icon, and the read of the Claude app's `preferences.menuBarEnabled` is gone.
- **Subprocesses** (`security`, `claude`) share `usageProcess`: no input, errors
  discarded, output capped at 1 MiB, stopped at the deadline or on cancellation.
- **Verified** with fakes and isolated defaults (`ClaudeLoginRenewalTests`,
  `ClaudeDesktopUsageTests`, `ClaudeSignInTests`): one renewal then a limits read, an
  unrenewable login asks for sign-in and backs off, other tools' logins are left
  alone, sign-in waits without starting Claude Code, the environment filter, the
  executable lookup, command quoting, the launcher's contents and permissions, and the
  process runner's deadline. **Not verified live:** a real renewal (the only login on
  the development Mac answered "OAuth session expired and could not be refreshed", so
  it needs one interactive sign-in) and the Terminal launcher, which was not opened.
