# Proposed large work items

**Status: proposed; awaiting breakdown approval and issue-tracker configuration.** These four substantial items consolidate the missing functionality into end-to-end deliverables. They are not yet published tracker issues. Requirements are in [product](product.md), with supporting evidence in [status](status.md).

## 1. Make background text correction reliable on macOS

**What it delivers:** With an existing supported provider configured, select text in another macOS application, press a preset hotkey, and get the transformed text inserted automatically and copied to the clipboard. Frog remains usable from its menu-bar icon and starts at login.

**Blocked by:** None; uses the current provider configuration and presets.

### Acceptance criteria

- [ ] Selection capture, processing, clipboard writing and automatic replacement form a single reliable execution path shared with manual processing where appropriate.
- [ ] Normal success requires no popup confirmation or settings window; the original editing application retains focus.
- [ ] No selection does not process stale clipboard content. Empty results, failed requests and denied permissions leave original text intact.
- [ ] A successful result remains on the clipboard. If focus/selection changes invalidate replacement, skip automatic paste and give actionable feedback.
- [ ] Repeated/overlapping hotkeys cannot mix requests, clipboard contents or replacement targets; define and expose busy/cancellation behavior.
- [ ] Hotkey registration failures and processing progress/errors are visible with settings hidden; resolve or replace the inconsistent popup/event wiring.
- [ ] A macOS menu-bar status icon opens settings and exposes Quit. Closing settings keeps hotkeys active; all Quit paths release resources and actually exit.
- [ ] Login startup is configurable and starts with settings hidden; first-time setup explains required macOS permissions and provider setup.
- [ ] Remote-only use starts without downloading or loading a local model. App-owned local processes are cleaned up on quit.
- [ ] Verify the workflow in a native text editor and a browser text field, including multiline Unicode text, permission denial, no selection, provider failure and focus changes. Add deterministic regression coverage for execution failure paths.
- [ ] Update the usage guide with actual setup steps, background behavior and tested macOS/application versions.

## 2. Deliver configurable rules with cloud and local provider choice

**What it delivers:** Configure providers once, then create preset or custom rules with their own hotkeys, model choices and translation languages. Run those rules from other applications through the reliable execution path.

**Blocked by:** 1, for integrated background execution and registration feedback. Provider/editor implementation can be prepared independently, but acceptance requires that path.

### Acceptance criteria

- [ ] A coherent rule editor supports name, instructions, hotkey, enabled state, provider/model, and rule-specific options; users can create, edit and delete custom rules.
- [ ] Supply spelling, proofreading, email and translation presets with useful editable hotkeys. Multiple translation rules can target different languages simultaneously.
- [ ] Support OpenAI, Gemini, Anthropic/Claude and custom OpenAI-compatible cloud endpoints using user-provided credentials; support Ollama/local compatible endpoints without mandatory cloud credentials.
- [ ] Keep multiple provider configurations, select provider/model per rule, and offer connection testing with clear credential, endpoint, rate-limit, unavailable-model and offline errors.
- [ ] A missing/deleted/invalid provider or model produces an explicit rule error; never silently reuse a previously active provider. Define what happens to rules referencing a deleted provider.
- [ ] Validate prompt placeholders and required fields, detect duplicate/invalid hotkeys, expose OS registration conflicts, and apply saved changes without restart.
- [ ] Persist rules, providers and options across restart; migrate existing actions, global hotkeys and provider settings without losing user customizations.
- [ ] Store cloud credentials using appropriate OS credential storage and migrate existing plaintext keys; do not include keys in ordinary configuration output or errors.
- [ ] Keep optional managed GGUF inference compatible with the rule model, without making it a prerequisite for cloud or Ollama use.
- [ ] Verify two rules use different providers/models and two translation hotkeys use different target languages. Cover provider protocol contracts with deterministic HTTP fixtures and record live integration checks separately.
- [ ] Document provider setup, local versus cloud behavior, rule examples and migration behavior.

## 3. Add optional local processing history

**What it delivers:** Turn history on to revisit transformations from background hotkeys or manual processing, copy previous results, and delete records; turn it off to stop recording.

**Blocked by:** 1, for a reliable shared execution outcome. Can proceed alongside 2; capture the currently resolved action/provider information and integrate richer rule metadata as it becomes available.

### Acceptance criteria

- [ ] Add a persistent history setting and a history view accessible from settings.
- [ ] Proposed default: history is disabled until enabled. Record successful transformations only while enabled, including those run with the window hidden.
- [ ] Records contain timestamp, original text, result, action/rule identity, resolved provider/model and translation language when applicable.
- [ ] Browse records, inspect input/output, copy results, delete an individual record and clear all records.
- [ ] Turning recording off stops new writes; explain that existing records remain until cleared. Handle an in-flight request completing after the setting is disabled.
- [ ] Store history locally, keep credentials out of records, and do not create alternate text-history logs while recording is disabled.
- [ ] Choose and document a bounded retention/storage policy before implementation; handle storage failures without preventing a successful text transformation.
- [ ] Verify restart persistence, disabled recording, clearing/deletion, in-flight toggle changes and manual/background consistency with meaningful tests.
- [ ] Document stored data, its location, default behavior and deletion controls.

## 4. Ship and verify the full background assistant on Linux and macOS

**What it delivers:** Installable, documented macOS and Linux builds that run the complete configured-rule workflow, background lifecycle and optional history on explicitly supported desktop environments.

**Blocked by:** 1, 2 and 3 for full-product release acceptance. Linux integration work can begin against item 1 while the other features progress.

### Acceptance criteria

- [ ] Replace macOS-only assumptions with platform-specific clipboard, selection capture, paste and hotkey integrations; keep application core behavior shared.
- [ ] Verify Linux compilation and resolve platform-specific key/modifier mappings and dependencies.
- [ ] Provide Linux tray/settings access, explicit Quit, configurable login startup and hidden-window operation.
- [ ] Assess X11 and Wayland capabilities early, choose supported environments and implement the available integration paths. Document compositor/portal requirements and unsupported cases explicitly; do not mark generic “Linux support” complete based solely on an X11 build.
- [ ] Exercise select → hotkey → provider → clipboard + replacement in real applications on each supported session type, including permissions, conflicts, focus changes and non-editable selections.
- [ ] Verify provider credentials, per-rule routing, settings migration and history work on both platforms.
- [ ] Produce repeatable installable builds with documented toolchain/system dependencies, supported OS versions and CPU architectures, startup installation/removal, and upgrade instructions.
- [ ] Add automated build/static checks and meaningful regression checks, plus a reproducible desktop smoke-test checklist with recorded results.
- [ ] Measure idle CPU/memory, startup behavior and optional local-model resource use; agree practical budgets and remove unnecessary background work.
- [ ] Update README/status to distinguish verified functionality from remaining limitations and explain troubleshooting for permissions, providers and Linux sessions.

## Approval and publication

Coverage check: item 1 covers background operation, login startup, the macOS status icon, and automatic clipboard/replacement; item 2 covers presets, custom rules, independent translation languages/hotkeys, user-owned cloud credentials and local models; item 3 covers optional history; item 4 covers Linux and installable, verified releases. The settings window is delivered and refined across these items. Windows remains outside scope.

Before publishing, confirm whether these four items are the desired granularity, whether any should merge/split, and whether the listed blockers genuinely gate their acceptance.

No project issue tracker or triage vocabulary was found. Run `/setup-matt-pocock-skills` to configure local files or a hosted tracker, then publish one approved ticket per item with its blocking relationships. Work the unblocked frontier: item 1 first, then 2 and 3, followed by full release acceptance in 4.
