# Native implementation contract

User replaced the previous architecture with **SwiftUI, native macOS only**. macOS 14+; Swift package with FrogCore and FrogApp. Preserve prior implementation in archive. Native system frameworks only, no Go/Wails/WebView dependency. Model definitions in native/FrogCore/Models.swift are shared API.

## Core owner

Own native/FrogCore excluding Models.swift, native/Tests/FrogCoreTests. Provide:

- `ConfigurationStore(directory: URL? = nil)`, `load() throws -> Configuration`, `save(_ configuration: Configuration) throws`. Default Application Support/Frog; atomic restrictive writes, errors preserve corrupt files. Expose `directory: URL`.
- `HistoryStore(directory: URL? = nil)`, `load(preferences: Preferences) throws -> [HistoryEntry]`, `append(_ entry: HistoryEntry, preferences: Preferences) throws`, `delete(id: UUID) throws`, `clear() throws`. Bounds 200 records/30 days defaults; disabled recording means no writes. Actor or thread safety appropriate; parent calls on main actor, synchronous file APIs okay small files.
- `KeychainStore()`, `read(providerID: UUID) throws -> String?`, `save(_ key: String, providerID: UUID) throws`, `delete(providerID: UUID) throws`. Security framework, no secret serialization.
- `LLMClient(session: URLSession = .shared)`, `complete(text: String, rule: Rule, provider: ProviderConfiguration, apiKey: String?) async throws -> String`. OpenAI compatible, Anthropic, Gemini and native Ollama /api/chat; safe errors, timeout/cancel/empty responses, sensible input validation. Rule.model overrides provider.model; {{language}} expansion, selected text is user message, don't interpolate selected text into system prompt. Provider connection test done by same complete call with small test rule in AppModel.
- meaningful tests URLProtocol fixtures persistence bounds/corruption/key validation and request/response/error behaviors. Core must not import AppKit or SwiftUI.

## Platform owner

Own native/FrogApp/Platform only. Import FrogCore. APIs @MainActor where UI/OS requires:

- `SelectionService()` with `capture() async throws -> TextSelection`; `TextSelection.text: String`, `replace(with text: String) async throws`. Use AX selection/element + pid + range/value snapshot, original target validation; retain successful output on NSPasteboard even if replacement invalid. AX trusted error to user. Clipboard copy fallback only if target+selection can be reliably validated; no stale clipboard, no unsafe paste. Native AXUIElement/CGEvent, not shell AppleScript. Preserve clipboard rich content on capture. Static `SelectionService.isTrusted: Bool`, `requestAccess()`, `openAccessibilitySettings()`.
- `HotkeyManager()` with `register(rules: [Rule], onTrigger: @escaping (UUID) -> Void) -> [UUID: String]` (errors keyed by rule id), `unregister()`. Native Carbon key released event registration, duplicate detection, scope lifetime; static `display(_ hotkey: Hotkey) -> String` and `hotkey(from event: NSEvent) -> Hotkey?`. Support show-settings hotkey separately? Parent can use menu, no additional reserved shortcut required.
- `LoginService.isEnabled: Bool`, `statusText: String`, `setEnabled(_ enabled: Bool) throws` using SMAppService.mainApp; no shell commands.
- `DesktopNotifications.post(title: String, body: String)` static, native user notifications, status visible in menu even if permissions denied. Permission request on explicit onboarding/setting action not every launch; expose `requestAuthorization()`.

## UI owner

Own native/FrogApp/Views only. SwiftUI native, no AppKit hosting except Hotkey recorder via NSViewRepresentable when useful. Use @EnvironmentObject var model: AppModel. Parent owns FrogApp.swift and AppModel.swift.

AppModel @MainActor ObservableObject API:

- @Published private(set) `configuration: Configuration`, `history: [HistoryEntry]`, `hotkeyErrors: [UUID:String]`, `isProcessing: Bool`, `status: String`, `errorMessage: String?`, `manualResult: String`, `isTestingProvider: Bool`.
- `saveRule(_ rule: Rule) throws`, `deleteRule(id: UUID) throws`, `saveProvider(_ provider: ProviderConfiguration, apiKey: String?, clearKey: Bool) throws`, `deleteProvider(id: UUID) throws`, `setDefaultProvider(id: UUID?) throws`, `hasAPIKey(_ id: UUID) -> Bool`.
- `testProvider(_ provider: ProviderConfiguration, apiKey: String?) async throws -> String`.
- `savePreferences(_ preferences: Preferences) throws`, `deleteHistory(id: UUID) throws`, `clearHistory() throws`, `refreshHistory()`.
- `processManual(text: String, ruleID: UUID)`, `cancelProcessing()`, `dismissError()`, `report(_ error: Error)`; manual result updated published.
- `setStartAtLogin(_ enabled: Bool)`, `refreshSystemStatus()`; published `startAtLogin: Bool`, `accessibilityGranted: Bool`, `loginStatus: String`.
- `showSettings()` opens settings window via AppKit window controller callback installed by app delegate; UI can call this.
- `setShortcutRecording(_ recording: Bool)` suspends Frog's global registrations while its native recorder has focus, then restores them so existing shortcuts can be recorded without triggering a rule.
- `exportConfiguration(to: URL) throws`, `importConfiguration(_ configuration: Configuration) throws`; `ConfigurationFile` in FrogCore validates/encodes/decodes and reads/writes the portable JSON format. Import backs up current settings, remaps unknown/changed provider credential identities and refreshes shortcuts/history settings. Text history and API keys are not transfer payloads.

Top view `MainView()` with native sidebar navigation for Rules / Providers / Try text / History / Settings. The user's latest direction is a modern Handy-inspired design with adaptive surfaces, rounded cards, clear typography and shortcut keycaps. Include onboarding for missing provider/accessibility, clear status/error UI, useful preset duplication, form validation, per-rule provider/model/language/hotkey/enabled controls, provider key keep/remove masking/testing, history view/copy/delete, bounded history prefs/startup/accessibility/notifications. UI owns selection hotkey recorder invoking HotkeyManager conversion/display. Don't require confirmation for automatic replacement. Prefer simple stable macOS14 APIs.

Parent integration composes app/menu lifecycle, AppModel pipeline, packaging script/Info.plist, builds, review and docs. Main menu is SwiftUI MenuBarExtra; window hidden on login/normal launch except first configuration. Native app target no sandbox because global accessibility/Carbon integration requires user granted access.
