# Frog product requirements

This document records the intended product described by the user. For implementation evidence, see [status](status.md); for the proposed delivery plan, see [work items](work-items.md).

## Purpose and platforms

Frog is a small, background desktop utility that transforms selected text using a user-configured LLM. macOS is the primary platform and Linux is also required. Windows is not required.

The normal interaction is a global hotkey inside the user's existing application. A conventional settings window is available from a macOS menu-bar status icon or a Linux tray entry. Frog should start at login, remain available when its window is closed, and have an explicit Quit action.

## Core interaction

1. The user selects text in an editable application and presses a rule's hotkey.
2. Frog captures that selection and applies the rule through its configured provider and model.
3. On success, Frog copies the result to the clipboard and replaces the original selection automatically.
4. The user continues working in the original application without opening Frog or approving a result popup.

Preserve meaning, tone, Unicode, and paragraph structure as appropriate to the selected rule. Return transformed text without unsolicited model explanations.

Failure behavior must be explicit: no selection, missing credentials, unavailable models, provider failures, and OS permission failures should give actionable feedback while the window is hidden. Do not mistake an old clipboard value for a new selection. If the original editing target is no longer valid, retain a successful result on the clipboard and report that replacement was skipped rather than pasting into an unrelated application.

“Anywhere” means supported selectable/editable desktop text fields. Read-only content can supply text but cannot be replaced. Document actual application and Linux desktop/session compatibility, including X11 versus Wayland, rather than claiming universal access.

## Rules and presets

A **rule** is a reusable text transformation with a name, instructions, assigned global hotkey, provider/model selection, and any relevant options such as a target language. The current implementation calls prompt definitions “actions”; its separate “app shortcuts” launch applications and are a different feature.

Required presets:

- Spelling correction.
- Proofreading/grammar correction.
- Email correction and professional wording.
- Translation, with independently configured languages and hotkeys.

Users can create, edit, enable/disable, and delete custom rules. They can configure multiple translation rules simultaneously, for example one shortcut for German and another for English. Hotkey conflicts and invalid bindings must be visible in settings.

Existing outline and summary actions can remain as additional presets. Application-launching shortcuts are existing extra functionality, not a requirement for the writing assistant.

## Providers and models

- Cloud providers use the user's own API key; Frog does not supply a shared key or require its own paid account.
- Explicitly support OpenAI, Google Gemini, and Anthropic/Claude, plus configurable OpenAI-compatible endpoints.
- Support local model services, particularly Ollama. Local-only use does not require a cloud API key.
- Users can keep multiple provider configurations and choose a provider and model for each rule.
- Settings should expose model/endpoint configuration and a way to verify a connection, with useful authentication, connectivity, and model-availability errors.

Generic endpoint support applies to compatible APIs; arbitrary providers with different protocols require adapters. Existing managed GGUF/llama-server functionality is an optional extra, not a prerequisite for using Frog or Ollama.

## Background lifecycle and settings

- Start at login, with a user-controllable setting.
- Run with the settings window hidden during ordinary use and login startup.
- macOS menu-bar status icon and Linux desktop tray access expose settings and Quit.
- Closing settings keeps hotkeys active; quitting releases hotkeys and stops app-owned processes.
- Settings cover rules, hotkeys, providers/models, startup, and history.
- Remain lightweight when idle; model downloads and local inference are optional and user-initiated. Concrete resource budgets remain to be measured and agreed.

## Optional history

Users can enable or disable a local history of processed text, browse previous input/output and rule details, copy results again, and clear stored records. Turning recording off must stop new records, including processing triggered while the window is hidden.

Proposed implementation defaults, pending approval: history starts disabled; turning it off preserves existing records until explicitly cleared; records include timestamp, input/output, rule, provider/model, and translation language where applicable. No retention period or record cap has yet been agreed.

## Completion standard

A release is ready when a fresh installation can configure a provider, use preset and custom hotkeys successfully in other applications, replace selections and retain clipboard results, run from login without a visible window, reopen settings through the desktop icon, and use optional history on the documented macOS and Linux configurations.

Verification includes real desktop smoke tests and deterministic tests for processing failures, configuration persistence, provider routing, and history behavior. Documentation must state which behaviors were actually verified and keep remaining limitations visible.
