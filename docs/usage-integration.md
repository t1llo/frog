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
reset countdowns and an elapsed-window tick. Percentages are whole numbers rounded
down in the menu bar, the popup and the dashboard alike, so 100% appears only once a
limit is reached, and used and left add up to 100. Plan readings identify their account
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
their local sources, with local records filling unreported days. A day after the
report's `stats_as_of` date that the account lists without tokens is not yet
aggregated, so it counts as unreported. A zero source value
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
  UTC chart dates. Missing account activity is labeled as a local-log fallback,
  charted by this Mac's own days and still offering 7d/30d only.
  Local logs can span accounts and do not pretend to match the selected quota login.
  Existing saved provider/source/metric choices are retained. Periods are whole
  hours or days ending with the current one, so "Last 7 days" is today and the
  previous six; each option in the period menu says so on hover.
- **Profiles:** the dashboard can select a Claude Code configuration folder, like
  standalone. This local-only path selects its quota login and lifetime cache and
  adds its project transcripts. Standard discovery also includes `.config/claude`;
  canonical duplicates are removed. The folder is not exported in preferences.
- **Refresh:** explicit refresh immediately rescans local counters, coalescing a
  request made during an existing scan. Visible dashboards/popups refresh local
  counters every ten seconds; hidden collection keeps its one-minute cadence. A
  dashboard whose window is closed, minimised or fully covered counts as hidden.
  Anthropic/OpenAI remote request gates and credential ownership are unchanged.
  A chart summary that ends after newer lines arrived is shown and then worked out once
  more; discarding it kept the charts at "Reading token activity…" while Claude Code
  wrote faster than a summary of the month took (`TokenStoreRescanTests`).
- **OpenCode reliability:** unchanged database/WAL metadata reuse parsed counters.
  Changes reread the bounded horizon, preserving mutable-row/revert/fork semantics.
  Temporary query failures retain the last readable counters with a visible warning;
  successful recovery clears it. Removed databases remove their counters. A database
  that never held usage tables is found and empty, without a warning. Reads use a
  read-only connection; only when it cannot reach the WAL index OpenCode removes on
  quitting is a normal connection tried. A cancelled scan opens nothing further.
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
  reader was written for Frog; no code was taken from other trackers. Frog looks at
  the file on every refresh and reads it again only once it has been replaced or its
  size or modification time has changed; a file over the size limit is not read at
  all. The cached Claude Code profile (`.claude.json`), which names the plan, is
  treated the same way on its own, and is read only when the reading names an
  organization.
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
- **How often the Claude app saves:** only while its menu-bar icon is switched on and
  was opened recently (conditions: see the 2026-10-13 follow-up below), which nothing
  outside the app can keep going; the file can stay untouched for days while the app
  is in daily use. It is a fallback, not a dependable source.
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
  The estimate is labeled "API estimate". Open dashboard is a menu row; the footer shows the reading's age and source.
- Opening either popup posts `frogMenuPopupWillOpen`; the other one closes.
- Without a plan reading the menu-bar item shows the selected period's API estimate
  ("7d $185") rather than only the provider name; a reading that could not be
  refreshed is drawn dimmed.
- Limit bars and pace labels use the theme's status tones: `good` under pace,
  `warning` ahead of pace, `critical` from 95 % used; on pace keeps the accent. The
  System monitor uses the same tones for disk and battery. Each built-in theme
  defines them and `palette.light`/`palette.dark` can override them.
- Graphs (2026-10-13) share one look, modelled on Linear's project graph
  (`GraphStyle.swift`): a legend of small squares with the value below, a thin smooth
  line over a fading fill, thin bars on the baseline, and a time axis that names only
  its two ends. No grid and no value scale; the pointer shows exact values. The
  activity chart draws the period's running total as the line and each day's (or
  hour's) amount as a bar on its own scale. The line colour is `FrogStyle.series`:
  the theme accent, or indigo in Minimal, whose own accent is a neutral grey. The
  System monitor draws CPU in that colour and GPU in the theme's `warning` tone.
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
  `/opt/homebrew/bin` and `/usr/local/bin`, then in the absolute entries of `PATH`, then
  in `~/.bun/bin`, npm-global, Volta and asdf, so that it agrees with the installed-tools
  list on whether Claude Code is there. The environment is reduced to home, user,
  locale, temporary folder, proxy and certificate variables with `PATH` set to the
  system directories; `CLAUDE_CONFIG_DIR` is passed only for a non-default profile.
  Working directory is the temporary folder. No tools, no MCP servers, no saved
  session; only the exit status is used. A poll's run is stopped after 90 seconds, a
  run for a sign-in after 30, because Terminal's sign-in follows if it fails. Only one
  run exists at a time: a sign-in that starts while a poll's run is under way waits
  for that run instead of starting a second one, and the run is counted once in the
  gate.
- **Gate** (`ClaudePollingState.nextRenewalAt`/`renewalInterval`, saved with the other
  gates; state from earlier versions still loads): at most one attempt per 30 minutes;
  a failed attempt waits one hour, then two, up to eight; "nothing to renew" or "no
  Claude Code" is looked at again after five minutes because it costs nothing. A
  successful limits read clears it.
- **Sign in:** when no current reading can be had without a login
  (`Store.needsClaudeCodeLogin`), the popup shows a "Sign in to Claude Code…" row and
  the dashboard a button. The action first checks whether a login is usable or can be
  renewed, and then opens nothing. While it checks, the row and the button read
  "Checking Claude Code’s login…" and are disabled, the status line says the same,
  and a second request is ignored. Otherwise it switches a `Claude Desktop` source to
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

## Follow-up: an update that never ran, and when the Claude app saves (2026-10-13)

Report, after 1.0.23 to 1.0.25 were published: Claude limits still not tracked. Three
causes on that Mac, none of them in the collector:

- **The fixes were not running.** The installed Frog was still 1.0.22. Sparkle had
  downloaded 1.0.23 and waits to install it until Frog quits, which a menu-bar app
  that starts at login rarely does. Frog now says so: when Sparkle reports an update
  it will install on quit (`willInstallUpdateOnQuit`), both menu-bar popups show
  "Update to x is ready…" and Settings → Updates shows the version with "Install and
  Relaunch…". Both run Sparkle's normal check, which resumes the staged update and
  offers to install it and relaunch. Frog only observes; Sparkle still installs on
  quit as before. The notice lasts until Frog quits and is not saved.
- **The Claude app was not saving.** Observed with Claude 2.31226.1, whose menu-bar
  icon was switched off in its settings: the file's last sample was three days old
  although the app was in daily use. The app checks its limits only while that icon
  exists, and then only for a limited time after the icon was last opened (a day at
  the time of writing; the app can change this), not while the Mac is idle or
  locked, at most every five to fifteen minutes. Frog does not read the app's
  settings to tell which of these applies; the status says "The Claude app saves its
  limits only while its menu-bar icon is on and was opened recently. Sign in to
  Claude Code and Frog checks them itself."
- **Claude Code was signed out**, so there was nothing to renew in the background.
  One interactive sign-in is needed; Frog never signs in for the user.

No other local source holds plan limits: Claude Code's transcripts and profile and the
Claude app's session files contain none, and the Claude app's own login is not read.

**Verified:** `UpdateReadinessTests` (the row exists only while a version is waiting),
the popup sizing and outside-click tests, and the status wording in
`ClaudeDesktopUsageTests`. Sparkle 2.10.0's source confirms that a check resumes a
staged update with "Install and Relaunch". **Not verified live:** a real update cycle
reaching the notice and the prompt opened from it.

## Several Claude accounts (2026-10)

People who use two Claude accounts on one Mac, for example through a second Claude app
started with its own folder, want to see both accounts' limits, each on its own or
combined. The pieces below find and name the accounts, read each one, and combine their
values. The screens that show them follow under "Showing each account"; until the
switch is turned on, Frog reads one Claude Code login and the default Claude app folder
exactly as before.

- **Finding accounts** (`ClaudeAccountDiscovery`). Claude app folders are the entries
  directly under `~/Library/Application Support` named `Claude`, `Claude-…` or
  `Claude …` (in any case) that hold `plan-usage-history.json` or a
  `claude-code-sessions` folder. Other apps such as `ClaudeUsageBar` are left out, and
  nothing below those folders is opened: not `config.json`, cookies or the app's
  storage. Claude Code profiles are `~/.claude` (its profile file is `~/.claude.json`),
  every `~/.claude-*` folder, `~/.config/claude`, the folder chosen with "Choose
  folder…", `CLAUDE_CONFIG_DIR` and any folder added later, kept when their
  `.claude.json` holds an `oauthAccount`. A folder reached twice, also through a
  symbolic link, counts once. The profile files are the only files read; running
  processes are never looked at.
- **Which folders are one account** (`ClaudeAccountMatching`). An account is anchored
  to a slot: a Claude app folder, or a profile that belongs to no app folder. The
  organization of a folder's newest history sample and a profile's
  `oauthAccount.organizationUuid` decide. A profile joins an app folder when exactly
  one app folder names its organization, the rule the plan badge already follows. An
  app folder's own Claude Code folder, the one its live readings sign in to
  (`Claude` has `~/.claude`, `Claude-Account-B` has `~/.claude-account-b`), joins it
  first, so another profile naming the same organization never takes its place; that
  one is merged into the account. The default profile is the exception: every Claude
  app's Claude Code sessions run in `~/.claude` and write `~/.claude.json`, so while B's
  app ran a session last, it names B although the login beside it is still A's. When
  it names an account that already has its own folder, it stays with the app folder
  whose own folder it is, `Claude`, if that one has none. Whichever account the
  default profile names, A reads `~/.claude` and B `~/.claude-account-b`. App folders
  naming the same organization are one account under the first folder, so a combined
  value never counts it twice, and the account says "Claude and Claude-2 are signed in
  to the same account". When a folder's newest organization changes, the slot keeps its
  label. Organization ids stay in memory; they are never shown, saved or exported.
- **Labels** (`ClaudeAccountLabels`). The default `Claude` folder is A; a folder named
  `Claude-Account-X`, `Claude X` or `Claude-X` is X; a profile `.claude-work` is
  "Work" (`.claude-account-x` and `.claude-x` are X); every other slot gets the next
  free letter, app folders by name first, then profiles. A new name is trimmed and cut
  to 16 characters, an empty one returns to the default, and a name another account
  has gets " 2", then " 3". The menu bar shows the first six characters. Labels and
  the include switches are saved on this Mac in `xyz.beffa.frog.usage` under
  `claudeAccounts.v1`, by slot path, and are never part of the configuration.
- **Polling state per account.** The slot of the default `Claude` folder, or without
  one the slot of the default profile, keeps `claudePollingState.v1`, so updating
  loses no cooldowns. Every other slot uses `claudePollingState.v1.` followed by the
  first 16 hexadecimal characters of the SHA-256 of its slot path; no key derives
  from a token.
- **Combined values** (`ClaudeAccountsCombination`). For one kind of window, the
  included accounts with a current reading count (a finite percentage whose window
  has not renewed). The value is Σ wᵢ·usedᵢ / Σ wᵢ. When every counted account has a
  known plan, the weights are the plan sizes (Pro 1, Max and Max 5× 5, Max 20× 20);
  otherwise every weight is 1, and the row says "Treats A and B as plans of the same
  size". Team, Enterprise and an unknown plan have no size. Included accounts left out
  are listed as missing, except one whose current reading has no model week of that
  kind: its plan may have none, such as Pro without Week · Opus. Every plan has a
  session and a week, so a reading without one of them is missing. A combined row has no renewal time and no pace, because each
  account renews on its own clock; its caption lists each account instead, such as
  "A 30% · resets 15:40 · B 80% · resets Thu 09:00". Percentages round down as every
  other row does, so used and left add up to 100.
- **Display choices.** The usage preferences gain `claudeAccounts` (off),
  `claudeAccountsView` (`each` or `combined`) and `claudeAccountsMenuBar` (`session`
  or `week`). Configuration files written before them load with these defaults.
  Their text keys are `usage.claude-accounts`, `usage.claude-accounts-view` and
  `usage.claude-accounts-menu-bar`.
- **Reading another folder.** `readClaudeDesktop(folder:profiles:)` reads any Claude
  app folder's history and takes the plan from whichever given profile names the same
  organization.

**Verified:** `ClaudeAccountDiscoveryTests`, `ClaudeAccountMatchingTests`,
`ClaudeAccountLabelsTests`, `ClaudeAccountsCombinationTests`, `ClaudeDesktopUsageTests`,
`UsageDisplayPreferencesTests` and `ConfigurationFileTests`, all against fixture folders
and isolated defaults.

### Reading each account

- **Switch off** (`claudeAccounts` false, the default). One store reads as before, with
  the login source and folder chosen on the page. While Mr. Usage is on, Frog looks for
  further accounts once per launch and on each Refresh, by folder names, the existence
  of files and whether each Claude Code profile file holds a login; no history file is
  opened. Because the app folders' histories are not read, the count is the larger of
  the Claude app folders and the Claude Code profiles found. With two or more, the popup and the page offer once: "Frog found 2
  Claude accounts on this Mac: the Claude app's "Claude" and "Claude-Account-B"
  folders. Show usage for each? Frog reads their saved limits locally." **Show both**
  (or "Show all 3") turns the switch on and saves it to the configuration; **Not now**
  saves `claudeAccountsNoticeDismissed` in `xyz.beffa.frog.usage` and the offer never
  returns. The switch stays on the page.
- **Switch on.** Every account gets a store of its own (`ClaudeAccountsModel`), and the
  one store stops, since it shares `claudePollingState.v1` with the default account.
  Each store works as Automatic does: it shows the newer of its endpoint reading and
  its Claude app reading, and borrows renewal times only from a reading of the same
  organization. It uses only its own Claude Code folder's login (Keychain item through
  `security`, as before); OpenCode and Pi logins name no account and are not used. A
  lapsed login is renewed through Claude Code under the same 30-minute gate, per
  account.
- **Separate gates, 30 s apart.** Each store saves its polling state under its own key,
  keeps the one-minute floor and learns its own backoff, so throttling of B never slows
  A. The stores start 30 seconds apart: A at once, B after 30 s, C after 60 s. Their
  Claude app files are read at once; only the first request waits.
- **Accounts known only from the Claude app** read that app's history and never send a
  request. When such an account's app reading is missing or older than 30 minutes and
  Claude Code is installed, the account offers live readings: the sign-in command for a
  new profile named after the app folder (`Claude-Account-B` gives
  `~/.claude-account-b`), `CLAUDE_CONFIG_DIR=… claude auth login`. Frog does not create
  that folder; Claude Code does when signing in, and the next detection links it to the
  app folder by organization.
- **An account whose own login is gone.** An account with a Claude Code folder whose
  login is missing, and no current Claude app reading, offers "Sign in to Claude Code…"
  in its row on the page and "Sign in to Claude Code for B…" in the popup. It checks
  and renews that folder's login first, as the single account's sign-in does, and only
  then opens Terminal with `CLAUDE_CONFIG_DIR=… claude auth login` for that folder.
  While each account is shown, the popup and the page offer no unnamed sign-in.
- **Activity of every account.** While the switch is on, the token activity and its API
  cost also read each account's Claude Code folders that the usual ones leave out, such
  as `~/.claude-account-b`, so "Each account" and "Combined" count every account's calls;
  a folder reached through a symbolic link is read once. Turning the switch off, or an
  account going away, starts the reading over without those folders.
- **A folder signed in to another account.** When the newest organization in an
  account's Claude app history changes, that account's endpoint reading and borrowed
  renewal times are dropped, Frog looks for accounts again, and the label stays.
- **For the screens**, `UsageDashboardModel` gives one summary per account (label,
  short label, Session and Week windows with the model weeks, plan, sources such as
  "Claude app · Claude-Account-B" and "Claude Code · ~/.claude", age, whether it is
  stale, status, a warning only while the reading is out of date, include switch,
  live-reading and sign-in offers, merged note), the combined
  windows, the notice, renaming, including, "Add folder…" (kept on this Mac under
  `claudeAccounts.v1.extraFolders`) and the live-reading command. No summary carries an
  e-mail address.

**Verified:** `ClaudeAccountsStoreTests` (separate gates, the 30 s start, the default
account's saved gate, nothing opened while the switch is off, the notice, an app-only
account sending nothing, the live-reading command with a space in the home folder, an
organization change, every account's Claude Code calls in the activity, no e-mail address), with `UsageParityTests`,
`UsageLifecycleTests` and `ClaudeLoginRenewalTests` unchanged.

### Showing each account

Everything here applies while Mr. Usage shows Claude, the switch is on and Frog has
found at least two accounts; otherwise the menu bar item, the popup and the page look
as before.

- **Offer.** While the switch is off and two or more accounts are found, the popup and
  the page show the offer above the limits, with **Show both** and **Not now**.
- **Menu bar.** *Each account* draws one entry per included account, `A 37%  B 81%`,
  for the session or the week (`usage.claude-accounts-menu-bar`), at most three; an
  account without a reading from the last 30 minutes is dimmed on its own.
  *Combined* looks like the one account's item with the combined values. The tooltip
  has one line per account and window, such as "B · Session 81% used · resets 17:10 ·
  Claude app, 2h ago"; combined, it starts with "A + B combined", the combined values
  and how they are weighted.
- **Popup** (still 292 points wide). *Each account* replaces the limit bars with one
  row per included account, at most four: label, plan, age and a warning when stale,
  then small Session and Week meters with the used share and the renewal ("15:40",
  "Thu"); hovering a row gives its status. *Combined* heads the bars "Plan limits · A +
  B", draws them without renewal or pace, and puts each account's share under each
  bar. The first account that can be set up for live readings gets the row "Set up
  live readings for B…" in place of "Sign in to Claude Code…". The footer reads "A 3m
  ago · B 2h ago", with the sources on hover.
- **Page.** The switch **Show each Claude account** appears once two accounts are found
  and stays while it is on. While on, an **Accounts** section replaces the "Claude Code
  profile" line: per account a label field (renamed on Return or when it loses focus),
  its sources, plan, last reading, status, the **Include** switch, **Set up live
  readings…** when it applies and the note for app folders that are one account. The
  login's e-mail address is only in the row's hover help. Below the rows: *Each account
  | Combined*, the menu bar's *Session | Week* (with two included accounts shown each),
  and **Add folder…** for a Claude app data folder or a Claude Code folder. The limits
  show one block per included account, or one combined grid with each bar's breakdown
  and the weighting. The login source menu is hidden while the switch is on.
- **Live readings.** Both the popup row and the page button explain first ("Set up live
  readings for B?") and open Terminal with `CLAUDE_CONFIG_DIR=~/.claude-account-b
  claude auth login` only after **Open Terminal**.

**Verified:** `UsageStatusReadoutTests` (each account's face and window, per-entry
dimming, three entries at most with every account described, the tooltip lines and the
combined basis, today's face unchanged), `TextConfigurationTests` (the three keys round
trip; an unknown view is refused), `ClaudeSignInTests` (the launcher runs the
account's command unchanged) and `ConfigurationReferenceTests`. The views were built,
not looked at on screen.
