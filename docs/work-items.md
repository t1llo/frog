# Native implementation work items

Approved scope: finish the native SwiftUI macOS app. The prior cross-platform plan is archived in `archive/planning/work-items.md`.

1. **Native processing foundation:** Swift models, cloud/local provider clients, Keychain credentials, atomic settings and bounded optional history, with protocol/persistence tests.
2. **Native desktop workflow:** global hotkeys, Accessibility capture/validated replacement, clipboard results, cancellation, menu-bar status, login startup and permissions.
3. **Complete SwiftUI app and release:** rules/providers/manual processing/history/settings UI, `.app` packaging, integrated verification, documentation and review.

Core, platform adapters and views can be built independently against `native-contract.md`; integrated acceptance depends on all three. Completion requires verification evidence, not just source presence.
