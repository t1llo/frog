# Vorssaint usage and graph reference

Research date: **2026-10-10**. Native source inspected at
[`47c2653c3ced7b0118ff88b653ebb2425c690021`](https://github.com/vorssaint/vorssaint-utils/tree/47c2653c3ced7b0118ff88b653ebb2425c690021).
Website sources are the public, version-query URLs served by [vorssaint.com](https://vorssaint.com/) on that date; they are not asserted to match this Git commit. This is source inspection, not an authenticated integration test or a browser pixel comparison. The initial research added only this note; the subsequent independently implemented collector audit is recorded below. No reference implementation or assets were imported.

## Main finding

**Use the compact graph presentation as inspiration, retain Frog's owned Mr. Usage collectors.** System sparklines, AI usage charts and the website demo are distinct. Vorssaint reads Claude quotas from a local file; Frog queries an authenticated endpoint. The website is a JavaScript recreation with synthetic readings. [W1], [W4], [W5], [C], [F1]

## How the native AI statistics are gathered

### Claude

- **Tokens/activity:** JSONL under `~/.claude/projects` and `~/.config/claude/projects`, including subagents. Assistant `message.usage` supplies input, output, cache creation/read, thinking, long-cache writes, fast/US inference flags and web searches. Message ID plus request ID identify responses; repeated observations merge counters. Dollar values use a price table. [R], [P1], [S]
- **Plan name:** `~/.claude.json` → `oauthAccount.organizationType`, `organizationRateLimitTier` / `userRateLimitTier`. The organization UUID selects relevant Desktop samples where available. This reads profile metadata, not OAuth access/refresh tokens. [V1]
- **Plan percentages:** `~/Library/Application Support/Claude/plan-usage-history.json`. Accepts versions 1/2, maximum 4 MiB, millisecond timestamp `t`, optional `org`, and percentages `fh` (five-hour), `sd` (seven-day), `so` (Opus), `sn` (Sonnet); v2 nests them under `u`. No Anthropic HTTP quota request is implemented here. [C], [V1]
- **Reset times are inferred:** the Desktop file lacks renewal timestamps. Samples and optional Claude Code activity bracket session start; percentage drops suggest weekly renewal. Old/expired windows are excluded; the UI dims readings after 30 minutes. A comment says Desktop checks every 5–15 minutes with its menu-bar icon on; that cadence is an upstream assertion, not independently verified. [C], [U1]

### Codex

- **Tokens/plan/limits:** `~/.codex/sessions` and `~/.codex/archived_sessions`. New `token_usage_record` events use response IDs; older `event_msg` → `token_count` uses cumulative totals / `last_token_usage`. `rate_limits` supplies windows and `plan_type`. Only the main `codex`/unnamed limit bucket is retained. [R], [P2], [P4]
- **Additional live account path:** when the banked-reset card is shown, Vorssaint locates the installed Codex executable and launches `codex -c features.plugins=false app-server`. It sends newline-delimited JSON RPC over stdin/stdout: `initialize`, notification `initialized`, `account/read`, then `account/rateLimits/read`. Account type must be `chatgpt`; the response yields `rateLimitResetCredits` plus `rateLimitsByLimitId.codex` / `rateLimits`. **Codex handles its own authentication; Vorssaint does not read its credentials for this path.** No underlying OpenAI HTTP endpoint can be established from this wrapper alone. [X]
- **Cadence/failures:** `refreshIfStale` waits five minutes after success/sign-out/outdated responses, 60 seconds after other failures. Serialized checks have a 20-second deadline and retain counts after unreachable/refused replies. This is fixed retry timing, not HTTP-429 backoff. Explicit refresh bypasses the staleness gate. [X], [X2]
- **Separate mutation:** the reset action uses `account/rateLimitResetCredit/consume`, an idempotency key, ten-minute retry window and 30-second timeout. It is unnecessary for observation and was not run. [X], [X2]

### OpenCode

- **Source:** exactly `~/.local/share/opencode/opencode.db`. SQLite opens `READONLY | NOMUTEX`, with a two-second busy timeout. Queries join `message`/`session`, extracting role, model, counters, cost, finish/time and working directory. `part` metadata identifies tool/compaction activity; prompt/reply bodies are not selected. [R], [O]
- **Incremental strategy:** watch DB/WAL, scan new rowids and changed unfinished replies, retain 64 `(rowid,id)` pairs to detect deletion/reuse, restart on DB replacement. OpenCode state is memory-only and rebuilt each launch. [O], [V2]
- **Meaning:** OpenCode is an agent/source category. Counts include cache read/write and output plus reasoning. Calculated known-model prices take precedence over recorded `cost`. **No OpenCode quota endpoint or auth-file read exists here.** Its limits-style card falls back to today's API value/tokens. [P3], [U1]

### GitHub Copilot

- **Source:** shallow discovery of `~/.copilot/session-state/<session>/events.jsonl`, avoiding workspace scans. This targets the CLI/app local format, not demonstrated coverage of all Copilot editor/cloud surfaces. [R], [P4]
- **Counters:** `assistant.message` supplies response activity, deduplicated by `apiCallId` or message/event ID and agent; `session.shutdown.modelMetrics` supplies cumulative per-model tokens and request counts. It accepts `tokenDetails.<kind>.tokenCount`, falling back to `usage.inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`, and `reasoningTokens`. Shutdown totals are added as growth since the previous checkpoint. Activity can therefore update before token totals. [P4]
- **No Copilot quota integration:** no premium-request entitlement/remaining-quota retrieval; Copilot is excluded from limit cards. These components use no GitHub auth token or billing endpoint. Dollars are API-price equivalents, not verified Copilot bills. [P4], [M]

## Collection, storage and network policy

- Feature/provider-gated collection runs on a utility queue, pauses when the island is away (including lock/sleep), and resumes cursors. Recent/active logs poll every **2 seconds**; a **30-second** sweep catches quieter files. Filesystem events and publications each coalesce at one second. The fast timer disarms when idle; history spans 13 weeks. [V2], [R]
- Private `agent-usage.bin` archives counters/cursors every five minutes and on pause/stop; disabling can remove it. It contains paths/session/project identifiers, **not raw conversation text**: the overview's “only counters” does not mean “no metadata.” OpenCode rows are excluded. [V2], [S], [A]
- **Price endpoint:** `https://raw.githubusercontent.com/vorssaint/vorssaint-utils/main/Resources/agent-prices.json`. Keep bundled/cached prices; update daily, retry failures after **six hours**. Ephemeral URLSession, no cookies/URL cache, same-host HTTPS redirects, 15-second request / 30-second resource timeouts, size bound. Non-200 responses fail without special `Retry-After` handling. [Q], [V3]
- Ordinary Claude/OpenCode/Copilot collection needs no cloud credentials; Codex account checks delegate auth. The usage overview's “one request” comment is not an app-wide no-network guarantee: the separate Codex service exists. [V2], [X]

## Graph / website design: system versus AI

### System-monitor graph reference

System/Network has compact label/value rows, thin meters and **30 px** sparklines: **1.5 pt** polyline, fading fill (**0.16** default), optional baseline, upper-left ceiling label. CPU/GPU/memory use 0–100%; network overlays download/accent and upload/green on a shared rounded-up scale, with labeled rate columns above. Native `Sparkline` uses straight segments with rounded caps/joins, not smoothed splines. [W1], [W2], [W3], [G]

The website generates random-walk system readings, retains **120 samples**, defaults to two-second ticks (options 1/2/5), and skips hidden-document updates. Its AI demo separately invents percentages and seeded history. This establishes an interactive preview, not real measurements or verified universal “1:1” fidelity. Exact viewport/Dock placement remains browser verification. [W4], [W5]

**Native** CPU uses Mach `host_statistics(HOST_CPU_LOAD_INFO)` busy/total tick deltas; GPU uses IOKit `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %`. Network uses `sysctl`/`NET_RT_IFLIST2` 64-bit byte-counter deltas, with a conditional process-counter download fallback. Long gaps discard rate baselines. These are system measurements, not AI APIs. [SYS], [NET]

### AI graph reference

AI cards show reset countdowns, used/remaining percentages and **4 pt meters with pace ticks**. Provider colors become orange at 80% used, red at 95%. Trends use **stacked bars**, hourly for Today/daily otherwise, hover readouts, sparse dates, and tokens when not fully priced. Models/projects show three ranked rows; activity uses a 13-week heatmap. [U1], [U2], [U3], [V2]

## Recommendations for Frog's owned Mr. Usage integration

These are design/integration recommendations, not newly implemented behavior. Local citations refer to the inspected working tree, which the parent session is actively editing.

1. **Keep the existing collector boundary.** Both the status-item popup and Features UI should render `UsageDashboardModel` windows/status/buckets/model totals. Preserve feature-owned background collection, cancellation and generation checks, rather than adopting island-visibility ownership. [F2], [F3]
2. **Separate plan percentage/reset, token history and estimated API value.** Use compact quota rows with 4–5 pt meters; hourly/daily bars for totals. A line/area alternative can borrow thin strokes, quiet fill and ceiling labels, retaining time/units. Frog already exposes 24h/7d/30d buckets and token metrics. [F2], [F3], [G], [U3]
3. **Retain Frog's direct Claude quota source.** It reads selected CLI/OpenCode/Pi access tokens read-only and calls `GET https://api.anthropic.com/api/oauth/usage` (Bearer, `anthropic-beta: oauth-2025-04-20`). It parses server resets, preserves identity, persists request gates, and doubles 60-second polling toward 600 on 429/5xx, honoring numeric/date `Retry-After`. Any future Desktop fallback needs source/age/estimated-reset labels. [F1], [F4], [C]
4. **Keep OpenAI account estimates identifiable.** Frog uses saved Codex/OpenCode access tokens without refresh at `https://chatgpt.com/backend-api/wham/` paths `usage`, `usage/plan_limit_history?days=30`, `profiles/me`, and optional `usage/daily-token-usage-breakdown`. Limits poll every two minutes/back off to ten; history waits ten minutes after success. Account UTC days replace overlapping local days. Model/token-kind splits and resulting API cost are estimates. These endpoints are observed in Frog code, not independently verified public API guarantees. [F5], [F3]
5. **Keep tools distinct from account providers.** Frog providers are Claude/OpenAI; Claude Code/Codex/OpenCode/Pi are sources. Its OpenCode reader accepts Anthropic/OpenAI/Azure. Vorssaint groups by agent and adds Copilot. Copilot would be new scope with delayed token totals and no demonstrated quota API; unsupported data should remain unavailable. [F3], [F6], [P4]
6. **Measure local scans separately from remote polling.** Vorssaint demonstrates file/WAL detection and cursors; Frog rereads the OpenCode horizon each minute for updates/reverts and supports channel databases/custom XDG roots. Any independent optimization must retain update/deletion/fork detection. Faster visuals must not bypass remote gates. [F3], [F6], [O], [R], [F1]
7. **Reproduce Frog itself in the website preview.** Use owned controls/theme/layout, labeled synthetic dashboard data and working provider/period/metric interactions. Compare native screenshots at agreed viewports. Vorssaint demonstrates this simulation approach, not browser access to real system/account statistics. [W4], [W5], [F2]

Reuse boundary: inspected native files identify **GPL-3.0-or-later**; the project's trademark document separately reserves name/logo/icon/branding/trade dress. This note records architecture and visual observations only; reuse of their implementation/assets would require a separate licensing decision. [L]

## Follow-up: local-source comparison and implemented fixes

The user-selected sibling checkout `vorssaint-utils` was read at the same commit.
Frog has no root license file in the inspected working tree; public availability was
not treated as permission to copy GPL implementation. Changes extend the owned
Mr. Usage code and use independently authored fixtures, not reference test/code text.

| Source evidence | Frog discrepancy / implemented behavior |
| --- | --- |
| `AgentLogParser.swift:269–277` accepts `session_id`, missing IDs; `AgentUsageStore.swift:163–236` merges repeated counters. | A fixture with a normal `session_meta` followed by `session_id` response records was dropped by Frog's `thread_id`-only predicate. Frog now accepts either owner field or omission, rejects explicit mismatches, gives missing response IDs a session/time/model key, and preserves counter high-water marks. |
| `AgentLogParser.swift:597–602` bounds Codex cache counts; `:315` namespaces cumulative records by session. | Frog now bounds cache reads/writes within input, validates counts, and namespaces legacy totals by session. Its additional explicit non-OpenAI `model_provider` exclusion is an independent account-scope rule, not a claim that Vorssaint implements it. |
| `AgentOpenCodeReader.swift:119–129,180–205,290–293` extracts only selected JSON metadata and guards invalid JSON. | A malformed row previously stopped Frog's query before a later valid row. Frog now guards JSON extraction and uses the database creation column when embedded time is absent. Existing SQLite/provider/channel support remains. |
| `AgentClaudeAppUsage.swift:63–109` distinguishes sampled percentages, inferred renewal and organization filtering. | Review exposed Frog's separate Codex behavior of turning an expired snapshot into zero. Expired windows now become unavailable; authenticated quota collectors and reset timestamps remain primary. Desktop fallback was deferred because automatic cross-account attribution and inferred resets cannot be silently equated with authoritative readings. |

Frog also exposes `UsageChart.sources` (`UsageSourceTotal.name/value/id`), aggregated
off-main alongside the existing cached summaries. It uses the same provider/range/
metric/account reconciliation as the chart. It adds no fake OpenCode provider, scans,
request cadence changes or portable preference fields. See
[usage integration](../usage-integration.md) for the parent UI integration contract.

Synthetic red/green evidence: initial reader fixtures produced **13 assertion failures
across three tests** (Codex, SQLite, expiry); final isolated FrogUsage suite passed
**14 tests / zero failures** under Xcode. Additional fixtures cover legacy session-key
collisions, malformed cache counts, source/provider separation and account-day
replacement. Existing fixture tests cover Claude streaming, cancellation and cooldowns.
No real account/log/credential reads or authenticated commands were used.

## Sources

[C]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentClaudeAppUsage.swift#L6-L146
[R]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentUsageStore.swift#L468-L909
[S]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentUsageStore.swift#L163-L415
[P1]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentLogParser.swift#L120-L245
[P2]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentLogParser.swift#L249-L352
[P3]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentLogParser.swift#L449-L532
[P4]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentLogParser.swift#L605-L793
[O]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentOpenCodeReader.swift#L7-L245
[M]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentUsageModels.swift#L6-L33
[V1]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentUsageService.swift#L655-L704
[V2]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentUsageService.swift#L8-L550
[V3]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentUsageService.swift#L706-L753
[A]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentUsageArchive.swift#L25-L94
[Q]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentPriceSource.swift#L6-L101
[X]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentCodexServer.swift#L27-L270
[X2]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/AgentUsage/AgentCodexResetService.swift#L8-L136
[G]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/UI/MenuPanel/Sparkline.swift#L6-L108
[SYS]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/SystemMonitor/SystemMonitor.swift#L1100-L1168
[NET]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/Services/Metrics/NetworkSampler.swift#L7-L139
[U1]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/UI/Notch/NotchAgentsView.swift#L121-L317
[U2]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/UI/Notch/NotchAgentsView.swift#L533-L707
[U3]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/Sources/Vorssaint/UI/Notch/NotchAgentComponents.swift#L7-L240
[L]: https://github.com/vorssaint/vorssaint-utils/blob/47c2653c3ced7b0118ff88b653ebb2425c690021/TRADEMARKS.md
[W1]: https://vorssaint.com/js/panel/sections/system.js?v=862d645153
[W2]: https://vorssaint.com/js/panel/sections/network.js?v=1884bd531e
[W3]: https://vorssaint.com/js/panel/kit.js?v=527ccd6d24
[W4]: https://vorssaint.com/js/panel/metrics.js?v=c55efcae76
[W5]: https://vorssaint.com/js/island/services/agents.js?v=88e1e6cea3
[F1]: ../../native/FrogUsage/Usage.swift
[F2]: ../../native/FrogUsage/UsageDashboardModel.swift
[F3]: ../../native/FrogUsage/TokenLog.swift
[F4]: ../../native/FrogUsage/ClaudePolling.swift
[F5]: ../../native/FrogUsage/OpenAIUsage.swift
[F6]: ../../native/FrogUsage/OpenCodeLog.swift
