# Native implementation status

The architecture changed to SwiftUI/macOS-only during implementation. The archived prototype inventory lives in `archive/planning/status.md`; it is not the status of the native app.

## Implemented

- Native SwiftUI rules/providers/manual text/history/settings interface, menu-bar lifecycle and a separate settings window.
- Configurable Carbon shortcuts, Accessibility selection capture and guarded replacement, clipboard results, cancellation and serialized processing.
- OpenAI, Anthropic, Gemini, Ollama and compatible protocol clients; per-rule provider/model/language; credentials in Keychain.
- Private atomic configuration/history persistence; history disabled by default with configurable limits up to 200 records/30 days.
- Login-item and notification integration; app bundle, icon, Xcode project, Swift package and macOS CI.

The latest user request is a modern Handy-inspired redesign. That visual pass is in progress across all sections.

## Verification evidence (2026-09-19)

- Integrated `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: **21 tests passed** (17 provider/persistence tests + 4 processing/routing/cancellation/history tests).
- Release `.app` built and its ad-hoc signature verified through `scripts/build-app.sh`.
- Xcode **Frog-macOS** Debug build passed. Initial multi-architecture Debug module mismatch was fixed by building only the active architecture for Debug.
- Packaged application launched with `FROG_DATA_DIRECTORY` pointing to an isolated temporary directory; a 1000×720 Frog window was observed through window metadata.
- Real Keychain create/read/update/delete passed using a generated provider UUID and disposable fixture values; the item was removed afterwards.
- Platform agent compiled against the macOS 14 deployment target and checked shortcut conversion/duplicate/invalid/disabled cases.

## Remaining external verification

The harness has neither Accessibility nor screen-capture permission. Live external text replacement/global shortcut delivery, login/logout startup and notification delivery remain unverified. No cloud account was used; Ollama (port 11434) and LM Studio (port 1234) were not listening during checks, so real model calls remain unverified. Protocol fixtures cover all supported request/response formats. Follow `verification.md` for desktop acceptance.

Distribution signing/notarization needs the owner's Apple Developer identity. Local ad-hoc signing is verified; notarization is not claimed.
