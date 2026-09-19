# Native implementation status

The architecture changed to SwiftUI/macOS-only during implementation. The archived prototype inventory lives in `archive/planning/status.md`; it is not the status of the native app.

## Implemented

- Native SwiftUI rules/providers/manual text/history/settings interface, menu-bar lifecycle and a separate settings window.
- Configurable Carbon shortcuts, Accessibility selection capture and guarded replacement, clipboard results, cancellation and serialized processing.
- OpenAI, Anthropic, Gemini, Ollama and compatible protocol clients; per-rule provider/model/language; credentials in Keychain.
- Private atomic configuration/history persistence; history disabled by default with configurable limits up to 200 records/30 days.
- Login-item and notification integration; app bundle, icon, Xcode project, Swift package and macOS CI.
- JSON configuration import/export, strict validation, backups before replacement and recovery of malformed saved settings. Credential identities are reused only for matching existing provider connections; keys/history are excluded from transfers.
- No telemetry/analytics SDK or Frog backend. Native network call sites are confined to configured provider requests.

The Handy-inspired visual redesign is integrated across all sections: adaptive light/dark surfaces, a branded sidebar, rounded cards and shortcut badges. The simplified README now includes native screenshots, installation/use instructions and config/privacy references. Repository visibility remains private.

## Verification evidence (2026-09-19)

- Integrated `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: **28 tests passed** (21 core protocol/persistence/configuration-file tests + 7 application processing/import tests), including save/export consistency and rejection without changing existing settings.
- Release `.app` built and its ad-hoc signature verified through `scripts/build-app.sh`.
- Universal release build passed; `lipo -info` confirms **arm64 + x86_64**, and `vtool -show-build` confirms a **macOS 14.0 minimum** for both slices. Xcode 27 emits an Intel deprecation warning, but the produced binary retains the requested macOS 14 deployment target. The zip preserves app permissions and bundle structure.
- Xcode **Frog-macOS** Debug build passed. Initial multi-architecture Debug module mismatch was fixed by building only the active architecture for Debug.
- Final packaged application launched with `FROG_DATA_DIRECTORY` pointing to an isolated temporary directory; its **1080×760** Frog window was observed through window metadata and the process reported finished launching.
- Real Keychain create/read/update/delete passed using a generated provider UUID and disposable fixture values; the item was removed afterwards.
- Platform agent compiled against the macOS 14 deployment target and checked shortcut conversion/duplicate/invalid/disabled cases.
- Final native views captured using `SCShareableContent.currentProcess` with isolated example settings: light/dark rules and configuration controls in `docs/images/`. Screenshots include the actual native window and do not capture other applications. Command–5 navigation to Settings executed successfully. The earlier view pass also inspected all five sections and the 940-point minimum width.
- The documented JSON example was accepted by `ConfigurationFile.read`; local Markdown links and screenshot paths were checked. ZIP extraction preserved executable permissions and a valid ad-hoc signature; `shasum -a 256 -c SHA256SUMS` passed.
- Private **draft** preview release `v0.1.0-preview.1` prepared with `Frog-macOS.zip` and `SHA256SUMS`; release notes are in `docs/releases/`. The repository remains private, and publication is a separate owner decision.

## Remaining external verification

The harness lacks Accessibility permission; it can capture its own native fixture windows through the macOS current-process API. Live external text replacement/global shortcut delivery, login/logout startup and notification delivery remain unverified. No cloud account was used; Ollama (port 11434) and LM Studio (port 1234) were not listening during checks, so real model calls remain unverified. Protocol fixtures cover all supported request/response formats. Follow `verification.md` for desktop acceptance.

Distribution signing/notarization needs the owner's Apple Developer identity. Local ad-hoc signing is verified; notarization is not claimed.
