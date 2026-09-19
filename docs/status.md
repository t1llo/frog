# Native implementation status

The architecture changed to SwiftUI/macOS-only during implementation. The archived prototype inventory lives in `archive/planning/status.md`; it is not the status of the native app.

In progress: native core (providers/Keychain/persistence/history), macOS platform integration (Accessibility/hotkeys/login), SwiftUI settings and menu-bar lifecycle. The root Swift package defines `FrogCore`, `FrogApp`, and behavioral tests. Verification results will be recorded here as integration completes.
