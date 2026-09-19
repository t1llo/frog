# Repository guidance

## Workflow and scope

Follow [the continuation workflow](docs/agent-workflow.md), including after automatic compaction. Recover the active objective from [progress](docs/progress.md). Continue the user's authorized native macOS implementation through verification; preserve approval boundaries and unrelated work.

## App boundaries

- Frog is a **native SwiftUI macOS 14+ app**, built with Swift Package Manager. Linux, Windows, Go/Wails and Svelte were superseded by the user's explicit architecture change.
- `native/FrogCore` owns models, persistence, Keychain and LLM clients; `native/FrogApp` owns SwiftUI, menu-bar lifecycle and native Accessibility/Carbon/ServiceManagement integrations.
- Read [native integration contracts](docs/native-contract.md) during parallel implementation. [Product requirements](docs/product.md) describe behavior; [status](docs/status.md) records verification evidence.
- `archive/` preserves prior code and historical planning. Archived instructions describe the old implementation and are not active app guidance.

## Commands and verification

- `swift build` and `swift test` from the root. Build/install the native app using `scripts/build-app.sh` once available.
- Xcode is installed at `/Applications/Xcode.app`; use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for Xcode tooling when the global selection points at CommandLineTools.
- Test provider protocols and persistence with isolated fixtures. Verify real hotkeys, Accessibility selection replacement, login startup and notifications separately from compilation.
- Keep cloud credentials in Keychain and local history optional. Use isolated data for tests; never alter the user's real provider configuration to run a smoke test.
