# Installed coding tools as text providers

## Integration contract

`FrogCore/LocalTool.swift` adds portable `LocalToolKind` values `claudeCode`,
`codex`, `opencode`. Store the kind plus the existing provider/rule model string;
an empty model means the CLI's available default. Do not serialize executable
paths, login state, tokens, or the machine's environment.

`FrogApp/Platform/LocalToolClient.swift` exposes an actor:

```swift
let localTools = LocalToolClient() // keep one on AppModel for capability caching
let statuses = await localTools.statuses(checkAuthentication: true)
let models = try await localTools.models(for: .opencode)
let request = try LocalToolRequest(
    kind: .claudeCode, text: text, rule: rule, providerModel: provider.model
)
let output = try await localTools.complete(request)
```

App integration uses matching `ProviderKind` cases and the portable model ID
`@default` for the tool default. `LocalToolRequest` converts that selection to an
omitted CLI model argument. Tool connections have an empty endpoint, skip Frog's
Keychain and route requests to this actor before `LLMClient`. Codex 0.159.x supports
restricted text execution through the same API. The dispatch serves writing,
translation, explicit provider tests, and dictation cleanup.

Return `output` into the existing Frog replacement/dictation-delivery pipeline.
The adapter never touches focus, selection, clipboard, or the insertion UI.
Rule model overrides provider model; `{{language}}` expansion is performed by the
request initializer. Cancellation propagates through the awaiting task.

Models → Installed tools embeds `LocalToolProvidersView(client:onSelect:)`.
“Use model” creates or updates the portable connection without an endpoint/key form;
its text models then appear in the existing rule model menus. Installation, login
and supported interface are shown separately.

### Codex support boundary

**Codex 0.159.x is enabled with a named deny-read/write permission profile.** This
supersedes the original unsupported result: a tool-free CLI contract was not found,
but supported filesystem permissions can deny model-selected actions instead.
Any detected tool attempt rejects the response, even if Codex later emits text.
Other minor versions remain unsupported until their permission/event contracts
are verified. Do not substitute `--sandbox read-only`: it allows private file reads
and overrides the named permission profile.

## Verified interfaces (2026-10-10)

Local presence and `--help`/`--version` were inspected. Codex was additionally run
against a loopback-only synthetic provider with temporary HOME/CODEX_HOME and no
credentials. No real login status, personal CLI config, account data, authenticated
model prompt, or clipboard was read during implementation verification.

| CLI | Installed version | Verified help |
| --- | --- | --- |
| Claude Code | 2.1.295 | top-level help; `auth status --help` |
| Codex | 0.159.0 | top-level help; `exec --help`; `login --help` |
| OpenCode | 2.0.26 | `run --help`; `models --help`; `auth --help`; `auth list --help` |

Discovery searches absolute entries in Frog's inherited PATH, then known user
installation locations (`~/.local/bin`, `~/.opencode/bin`, `~/.bun/bin`, npm-global,
Volta, asdf), Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`), and system directories.
It follows installed symlinks and supports spaces. It never invokes a login shell
or sources `.zshrc`/`.zprofile`. A GUI launch cannot recover arbitrary PATH mutations
from executable shell profiles safely; installations in those custom locations
must be on Frog's inherited PATH. No executable path enters portable preferences.

### Claude Code

The effective command is direct argv, with text on stdin and instructions in a
private temporary file:

```text
claude -p --output-format json --input-format text --safe-mode
  --tools "" --disallowedTools "*"
  --strict-mcp-config --mcp-config {"mcpServers":{}}
  --setting-sources "" --settings {"disableAllHooks":true}
  --permission-mode dontAsk --permission-prompts none
  --no-session-persistence --disable-slash-commands --no-chrome
  --max-turns 1 --system-prompt-file <private-file> [--model <model>]
```

`--safe-mode` preserves authentication. **Do not use `--bare`**: the installed
help explicitly says it skips OAuth and Keychain and only accepts API-key/helper
auth. `--tools ""` removes built-ins; deny-all plus strict empty MCP config removes
MCP tools; hooks and project/user customization are disabled. Managed organization
policy remains authoritative in Claude Code; installations whose policy disallows
these settings must fail rather than relax the invocation.

Only a JSON `type=result`, `subtype=success` string `result` is accepted. Tool
permission denials, errors, empty output, and incomplete turns are rejected.
`auth status --json` is reduced to the `loggedIn` boolean; account metadata is never
shown or persisted. Suggestions are documented aliases `haiku`, `sonnet`, `opus`,
plus CLI default and validated custom model IDs, not an entitlement claim.
Claude Desktop by itself has no supported headless adapter here.

### OpenCode V2

```text
opencode run --standalone --format json --agent frog-text
  --title "Frog text transformation" [--model <provider/model#variant>]
```

Stdin carries JSON with separate `instructions` and `text` fields. An isolated
temporary HOME and XDG config directory exclude user/project AGENTS, plugins,
hooks, `.claude`, and `.agents`. `OPENCODE_DISABLE_PROJECT_CONFIG=1` stops ancestor
configuration discovery; model-catalog background fetching and file watching are
disabled. The original XDG data location is passed to the CLI so its credential
database and refresh mechanism keep working; Frog never opens that database.
The private config defines a primary `frog-text` agent with a wildcard **deny**
permission rule and `steps: 1` (V2 removes tools on the last step), disables
snapshots, warming, updates, plugins and additional skills.

`--standalone` avoids an existing shared service and its loaded configuration.
OpenCode starts a private server with a stdin ownership lease; closure when the
CLI exits/kills causes that server to shut down. Frog does not stop/restart any
existing shared OpenCode service. No `--auto` or bypass flag is passed.

OpenCode JSONL `text` events supply only `part.text`; reasoning, startup information
and diagnostics are not returned. A `step_finish` with `reason=stop` is required;
tool-use events, errors and incomplete responses fail without insertion.
`models --standalone` returns available provider/model IDs, validated before UI use.
`auth list --standalone --format json` lists connection metadata, not exported
credentials; only presence of connections is retained. A login check says that a
CLI connection exists, not that every model/provider is authorized.

**Retention:** OpenCode V2 `run` has no verified ephemeral/no-history flag. Its own
database retains CLI sessions even when Frog history is off. Frog's temporary
files are deleted. Do not claim Frog's history switch controls another tool's
history. Isolated customization means user-defined custom provider aliases are
not imported; use an available built-in provider/model or the CLI default.

### Codex 0.159.x

The direct noninteractive shape is:

```text
codex exec --strict-config --ignore-user-config --ignore-rules
  --skip-git-repo-check --ephemeral --json --color never
  -c 'default_permissions="frog-text"'
  -c 'permissions.frog-text.filesystem={":root"="deny"}'
  -c 'permissions.frog-text.network.enabled=false'
  -c 'approval_policy="never"' -c 'approvals_reviewer="user"'
  -c 'web_search="disabled"'
  -c 'model_instructions_file="<private-file>"'
  <additional fixed customization/tool settings> [--model <model>] -
```

`LocalToolInvocation.codexSettings` is the complete fixed setting list. It disables
shell, patch feature, image, web, browser/computer, MCP app/plugin, subagent, hook,
skill-discovery, memory, code-mode and permission-request features. It also disables
project instructions, history, model-catalog refresh and background updates. Logs
and SQLite state go into the temporary workspace. JSON-framed instructions/text
travel through stdin; model instructions use a temporary file.

`features.shell_tool=false` removes the shell tool, but
`features.apply_patch_freeform=false` alone is **not** a reliable patch-tool
prohibition: model metadata and tool registration also participate. The named
filesystem profile denies reads and writes at `:root`, without enabling platform
default read roots or a writable cwd. Network access for sandboxed commands is
disabled. Codex's own provider/auth network remains available. This is a supported
Codex permission profile, not a custom Frog sandbox or private app-server API.
The checked `ThreadStartParams`/`TurnStartParams` do not expose a general tool allowlist
that would replace these restrictions.

`--ignore-user-config` explicitly preserves `CODEX_HOME` authentication. Frog passes
the original absolute CODEX_HOME (or `~/.codex`) with temporary HOME/XDG directories;
`cli_auth_credentials_store="auto"` supports the CLI's own Keychain/file credentials.
Frog never opens those stores. Custom provider aliases and user model defaults are
not imported; an empty model uses Codex's built-in default. Login status uses only
`codex login status`, never login, export, or auth-file reads.

Only the last `item.completed`/`agent_message` followed by `turn.completed` qualifies.
Reasoning is discarded; tool items and setup/model errors reject the response.
**Observed JSONL gap:** a denied pre-execution `apply_patch` read can be absent from
JSONL while the CLI exits zero with final text. The pinned router reports it to
stderr as `codex_core::tools::router: error=…`; Frog enables that error target with
`RUST_LOG` and rejects this diagnostic too, without exposing its private detail.
This version-sensitive behavior is why support is gated to 0.159.x.

## Process and privacy properties

- `posix_spawn` executes a discovered binary with direct argv and pipes. No Terminal,
  AppleScript, UI automation, shell-interpolated prompt, or borrowed OAuth token.
- Working directory is a fresh mode-0700 temporary directory. Selected text is
  stdin, not process arguments. Prompt files and generated config are removed.
- Only a small allowlist of environment values is passed. Shell/Node injection,
  inherited API keys and arbitrary tool config overrides are not forwarded.
- Defaults: 90-second deadline (maximum configurable 300), 4 MiB for each output
  stream, 1,000,000-byte text, 100,000-byte instructions. Pipes are serviced together
  to avoid stdout/stderr/stdin deadlocks. Oversized/truncated output is an error.
- Every direct child owns a new process group. Cancellation, timeout, output-limit
  failure and normal completion kill that group. The child is not reaped until
  cleanup, preventing a recycled PID from being targeted. Unrelated groups survive.
- Bounded stdout/stderr remain transient. Diagnostics are mapped to allowlisted
  login/quota/version/exit-status errors; raw prompts, tokens, emails, paths and
  CLI reasoning are not put into Frog logs or the insertion pipeline.
- No automatic login, account switching, permission approval, network model test,
  installation, or update occurs. CLI refresh of its existing credentials remains
  CLI-owned. Provider requests still leave the machine according to that tool's
  selected provider and account policy.

## Verification and performance

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LocalTool`
passed: **2 core + 12 app tests, 0 failures**, 2026-10-10. This also built the
SwiftUI subsection and process adapter. The final fixture benchmark reported
**11.13 ms median / 255.69 ms maximum** across 12 launches. The first-launch
outlier is included; these are synthetic subprocess numbers, not model latency.
`git diff --check` and new-file whitespace checks passed. Existing unrelated
Swift concurrency/CoreData diagnostics appeared in the test harness.

Codex follow-up: a separate temporary Swift package containing copies of FrogCore,
the adapter and its tests passed **2 core + 15 app tests, 0 failures**. It used its
own build directory, not the parent lane's build. Added fixtures cover supported
versus unverified Codex versions, environment/auth-location isolation, deny-read/write
arguments, TOML path escaping, and rejection of denied tools missing from JSONL.

The actual installed Codex 0.159.0 was also exercised against a local HTTP mock
Responses provider, with no auth and synthetic temporary files. Four probes passed:
plain-text completion; attempted `apply_patch` delete requiring a file read;
attempted `apply_patch` file creation; and attempted shell file read. In all three
tool probes the private sentinel remained unchanged, no new target file appeared,
no sentinel content reached the mock provider, and the router diagnostic was
detectable for rejection. A synthetic unsafe user config was ignored. These probes
use the adapter's fixed settings plus only loopback provider/model and ephemeral
credential-store overrides. Provider access with a real account remains untested.

Fixture tests cover path discovery, symlinks/spaces, exact stdin, environment
isolation, separate streams with large duplex input, malformed/truncated JSON,
reasoning/tool rejection, authentication-state distinction, workspace deletion,
output limits, deadlines, cancellation including child processes, and unrelated
process survival. Tests use synthetic executable scripts and isolated paths only.

The benchmark measures 12 fixture subprocess launches plus completion parsing;
it does **not** measure CLI startup or an authenticated network request. Real
latency includes tool startup, auth refresh, server queueing and model inference;
background operation is not an instant-response guarantee. Capability help is
cached against executable modification time, and no login/model-list subprocess
is inserted before every text request.

## Primary sources

1. [Claude CLI reference](https://code.claude.com/docs/en/cli-reference): print/JSON,
   safe/bare modes, disabled tools, MCP, auth status, persistence and prompt files.
2. [Claude headless mode](https://code.claude.com/docs/en/headless): unattended output
   and permission behavior.
3. [Codex noninteractive mode](https://developers.openai.com/codex/non-interactive-mode.md):
   stdin, JSONL event types, ephemeral sessions, authentication and sandbox semantics.
4. Codex 0.159.0 primary sources:
   [permission profiles](https://learn.chatgpt.com/docs/permissions.md),
   [pinned configuration schema](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/core/config.schema.json),
   [profile resolution](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/core/src/config/permissions.rs),
   [tool registration](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/core/src/tools/spec_plan.rs),
   [patch handler](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/core/src/tools/handlers/apply_patch.rs),
   [exec implementation](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/exec/src/lib.rs),
   [thread parameters](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/app-server-protocol/schema/typescript/v2/ThreadStartParams.ts),
   [turn parameters](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/app-server-protocol/schema/typescript/v2/TurnStartParams.ts).
5. [OpenCode V2 CLI](https://opencode.ai/v2/docs/cli),
   [configuration](https://opencode.ai/v2/docs/config),
   [agents](https://opencode.ai/v2/docs/agents),
   [permissions](https://opencode.ai/v2/docs/permissions),
   [instructions](https://opencode.ai/v2/docs/instructions).
6. Version-pinned upstream source supplements undocumented JSONL details:
   [run and stdin](https://github.com/anomalyco/opencode/blob/v2.0.26/packages/cli/src/run/run.ts),
   [JSONL output](https://github.com/anomalyco/opencode/blob/v2.0.26/packages/cli/src/run/noninteractive.ts),
   [auth list metadata](https://github.com/anomalyco/opencode/blob/v2.0.26/packages/cli/src/commands/handlers/auth/list.ts),
   [model list](https://github.com/anomalyco/opencode/blob/v2.0.26/packages/cli/src/commands/handlers/models.ts),
   [standalone server lease](https://github.com/anomalyco/opencode/blob/v2.0.26/packages/cli/src/services/standalone.ts),
   [environment controls](https://github.com/anomalyco/opencode/blob/v2.0.26/packages/cli/src/server-process.ts),
   [credential ownership](https://github.com/anomalyco/opencode/blob/v2.0.26/packages/core/src/credential.ts).
