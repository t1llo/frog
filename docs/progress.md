# Current progress

- **Objective:** Finish Frog as a native SwiftUI macOS-only app. The user superseded Go/Wails and Linux support; archive the former implementation rather than deleting it.
- **Completed:** Archived old app code and preserved both working-tree and staged Xcode snapshots; preserved abandoned parallel Go groundwork. Added Swift package, shared native models, integration contract and updated requirements.
- **Decisions:** macOS 14+, native system frameworks, SwiftUI menu-bar app; Keychain credentials; cloud BYOK and Ollama; history off by default with 200-record/30-day bounds. User authorized implementation through completion. Existing historical documents remain in archive.
- **Verification:** Swift 6.3.3 and Xcode 27 available (Xcode through explicit DEVELOPER_DIR). Native implementation checks pending. Earlier Go/frontend checks apply only to the archive.
- **Next steps:** Parallel native core/platform/views, parent app orchestration and packaging; integrate, build/test, review and record genuine desktop verification limits. Branch remains `feat/background-writing-assistant`, draft PR #1 will be updated for native scope.
