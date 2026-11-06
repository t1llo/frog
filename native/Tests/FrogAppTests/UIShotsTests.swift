import XCTest
import AppKit
import SwiftUI
import FrogCore
import FrogTestSupport
import FrogUsage
@testable import FrogApp

/// Pictures of every surface of Frog a user sees, in light and dark, for a design review from one folder: each page of
/// the window and the pages behind a tab or an entry, the menu-bar popup and each of its tabs, the popups of the
/// features with their own menu-bar item, the command bar, clipboard history, the window switcher and layouts, the
/// answer panel, the selection bubble, the dictation popup, the small notices, each setup step and the sheets.
///
/// Everything is drawn without a window from isolated sample data: a temporary data folder, a private pasteboard and
/// fixture files, never this Mac's Frog data or settings. Runs only with `FROG_UI_SHOTS` set to the folder for the
/// pictures, which are named `<surface>-<light|dark>.png`; `FROG_UI_SHOTS_ONLY` takes a comma-separated list of
/// surface names or prefixes (`menu,sheet-`). `scripts/ui-shots.sh <folder>` runs it.
@MainActor
final class UIShotsTests: XCTestCase {
    private var folder = ""
    private var only: [String]?
    private var written: [String] = []

    func testEverySurface() async throws {
        guard let folder = ProcessInfo.processInfo.environment["FROG_UI_SHOTS"] else {
            throw XCTSkip("Set FROG_UI_SHOTS to a folder to take these pictures")
        }
        self.folder = folder
        only = ProcessInfo.processInfo.environment["FROG_UI_SHOTS_ONLY"]?.split(separator: ",").map(String.init)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frog-ui-shots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = try await SampleFrog(root: root, defaults: temporaryDefaults())
        defer { sample.stop() }

        try await mainWindow(sample)
        try await menuBar(sample)
        try await keyboardPanels(sample)
        try await answerAndBubble()
        try await dictation(root: root.appendingPathComponent("dictation", isDirectory: true))
        try await notices(sample)
        try await setup(sample)
        try await sheets(sample)
        XCTAssertFalse(written.isEmpty, "No surface matched FROG_UI_SHOTS_ONLY")
        print("UI shots: \(written.count) pictures in \(folder)")
    }

    // MARK: The window

    private func mainWindow(_ sample: SampleFrog) async throws {
        let model = sample.model
        let routes: [(String, ToolkitRoute)] = FeatureID.allCases.map { ($0.rawValue, .feature($0)) }
            + [("history", .history), ("models", .models), ("features", .features), ("settings", .settings),
               ("statistics", .statistics)]
        for (route, value) in routes where wanted("page-\(route)") {
            model.toolkit.select(value)
            try await page("page-\(route)", settle: .milliseconds(500)) { MainView().environmentObject(model) }
        }
        // Behind an entry or a tab, drawn as the page column the window shows them in.
        if let entry = model.history.first {
            try await page("page-history-detail", width: 760) { HistoryView(viewing: entry.id).environmentObject(model) }
        }
        for (name, tab) in [("directory", PluginsTab.browse), ("build", .build)] {
            try await page("page-plugins-\(name)", width: 760) { PluginsView(plugins: model.plugins, tab: tab).environmentObject(model) }
        }
        for (name, filter) in [("local", "Local models"), ("providers", "Providers"), ("tools", "Installed tools")] {
            try await page("page-models-\(name)", width: 760) { ProvidersView(filter: filter).environmentObject(model) }
        }
        if let cleaner = model.cleanerPlugin?.cleaner, wanted("page-cleaner-review") {
            await cleaner.open(sample.cleanerApp)
            await cleaner.waitForSizes()
            try await page("page-cleaner-review", width: 760) { model.cleanerPlugin!.page()!.environmentObject(model) }
        }
    }

    // MARK: The menu bar

    private func menuBar(_ sample: SampleFrog) async throws {
        let model = sample.model
        try await popup("menu-frog") { FrogStatusMenu(model: model).environment(\.locale, L10n.locale) }
        for tab in model.pluginHost.menuTabs {
            let name = tab.id.hasSuffix(".tab") ? String(tab.id.dropLast(4)) : tab.id
            try await popup("menu-\(name)") { FrogStatusMenu(model: model, tab: tab.id).environment(\.locale, L10n.locale) }
        }
        try await popup("popup-llm-usage") { UsageStatusPopover(usage: sample.usage, openDashboard: {}) }
        if let monitor = (model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)?.monitor {
            try await popup("popup-system-monitor") { SystemMonitorStatusPopover(monitor: monitor) {} }
        }
        // Stay awake's menu-bar item opens an NSMenu, which only AppKit draws, on screen.
        try await focusTimerPopup(sample)
    }

    /// The example plugin's popup is a web page: drawn by WebKit in a window far off every screen, as
    /// `frog plugin snapshot --popup` draws it.
    private func focusTimerPopup(_ sample: SampleFrog) async throws {
        guard wanted("popup-focus-timer") else { return }
        // The example as published, with its popup; the installed copy lacks only the menu-bar item.
        let package = try PluginPackage.read(SampleFrog.repository.appendingPathComponent("plugins/focus-timer"))
        for (appearance, name) in Self.appearances {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            defer { NSApplication.shared.appearance = nil }
            let host = PluginWebHost(package: package, contentRules: nil, runtime: sample.model.plugins, inspectable: false, surface: .popup)
            // Frog answers a popup's calls only from the popup it opened.
            sample.model.plugins.popups[sample.focusTimerID] = host
            host.load()
            let png = try await host.snapshot()
            host.stop()
            sample.model.plugins.popups[sample.focusTimerID] = nil
            try write(png, "popup-focus-timer-\(name)")
        }
    }

    // MARK: Keyboard panels

    private func keyboardPanels(_ sample: SampleFrog) async throws {
        let model = sample.model
        let bar = CommandBar(model: model, pasteboard: sample.pasteboard, captureTarget: { nil }, waitForRelease: {},
                             fileSearch: NoFileSearch(), loadSettings: { [] }, loadApplications: { [] })
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        try await popup("command-bar-empty", size: CommandBarView.size) { CommandBarView(bar: bar) }
        bar.query = "win"
        try await popup("command-bar-query", size: CommandBarView.size) { CommandBarView(bar: bar) }

        let clipboard = ClipboardHistoryPanelState()
        clipboard.update(sample.history.entries)
        clipboard.selectedIndex = 2
        try await popup("clipboard", size: ClipboardHistoryLayout.size(entryCount: clipboard.visible.count)) {
            ClipboardHistoryView(state: clipboard, paste: { _, _ in }, copy: { _ in }, close: {}, resize: {})
        }

        let switcher = WindowSwitcherDisplay()
        switcher.windows = [
            SwitcherWindow(id: UUID(), pid: 1, appName: "Safari", title: "Frog — Command bar", minimized: false, hidden: false),
            SwitcherWindow(id: UUID(), pid: 2, appName: "Notes", title: "Groceries", minimized: false, hidden: false),
            SwitcherWindow(id: UUID(), pid: 3, appName: "Terminal", title: "~/Projects/frog", minimized: true, hidden: false),
            SwitcherWindow(id: UUID(), pid: 4, appName: "Mail", title: "Inbox", minimized: false, hidden: true),
            SwitcherWindow(id: UUID(), pid: 5, appName: "Calendar", title: "November", minimized: false, hidden: false)
        ]
        switcher.selected = switcher.windows[1].id
        try await popup("window-switcher", size: WindowSwitcherLayout.size(windowCount: switcher.windows.count)) {
            WindowSwitcherOverlay(model: switcher, choose: { _ in }, hover: { _ in })
        }

        let picker = LayoutPickerPanel()
        try await popup("window-layouts") { LayoutPickerView(panel: picker, measuring: true) }

        let preferences = model.configuration.preferences
        let switches = WindowSwitches(preferences)
        let commands = switches.shortcutRules.compactMap { rule in
            WindowCommand.command(for: rule.id).flatMap { command in rule.hotkey.map { (command, $0) } }
        }
        let rules = model.configuration.rules.filter { preferences.ruleFeatureEnabled($0) }
        let sections = WindowCheatSheet.sections(rules: rules, commands: commands)
        let cheatHeight = min(WindowCheatSheetPanel.maximumHeight,
                              ceil(NSHostingView(rootView: WindowCheatSheetContent(sections: sections).frame(width: WindowCheatSheetPanel.width)).fittingSize.height))
        try await popup("window-cheat-sheet") { WindowCheatSheetView(sections: sections, height: cheatHeight) }

        let groups = model.shortcutReferenceGroups
        let referenceHeight = min(ShortcutReferencePanel.maxHeight,
                                  ceil(NSHostingView(rootView: ShortcutReferenceContent(groups: groups).frame(width: ShortcutReferencePanel.width)
                                    .environment(\.locale, L10n.locale)).fittingSize.height))
        try await popup("shortcut-reference") { ShortcutReferenceView(groups: groups, height: referenceHeight) }

        // The zones a window held with Shift drops into, over a small display.
        let display = WindowDisplay(id: "1", name: "Display", frame: CGRect(x: 0, y: 0, width: 960, height: 600),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 960, height: 600))
        let zones = SnapZoneOverlayModel()
        zones.layout = SnapZoneLayout(display: display, grid: .thirds, options: WindowLayoutOptions(gap: 8), highlight: .leftThird)
        try await popup("window-snap-zones", size: CGSize(width: 960, height: 600)) {
            SnapZoneOverlayView(model: zones).background(Color.gray.opacity(0.25))
        }
    }

    // MARK: Answer panel and bubble

    private static let answer = """
    **Idempotent** means that doing something more than once has the same effect as doing it once. Here it describes \
    an API request: if the connection drops and the app sends it again, the server does not create a second order.

    - Setting a value to 5 is idempotent.
    - Adding 5 to it is not.

    Developers make retries safe by sending a unique `request-id` that the server remembers.
    """

    private func answerAndBubble() async throws {
        func session(_ change: (inout AnswerSession) -> Void) -> AnswerSession {
            var session = AnswerSession(rule: Rule.explainPreset, modelName: "gpt-5-mini", modelLabel: "gpt-5-mini · OpenAI",
                                        selection: "Requests must be idempotent so that retries are safe.", context: nil,
                                        application: "Safari", source: nil, replyLanguage: "English")
            change(&session)
            return session
        }
        let states: [(String, AnswerSession, (AnswerPanelModel) -> Void)] = [
            ("answer-panel", session { $0.apply(.text(Self.answer)); $0.complete() }, { $0.offersNotes = true; $0.canSaveNote = true }),
            ("answer-panel-streaming", session { $0.apply(.text(String(Self.answer.prefix(120)))) }, { _ in }),
            ("answer-panel-failed", session { $0.fail("Ollama is not running. Start it and try again.") }, { $0.recovery = .retry })
        ]
        for (name, session, configure) in states where wanted(name) {
            let panel = AnswerPanelModel()
            panel.session = session
            configure(panel)
            var height: CGFloat = 0
            panel.heightChanged = { height = $0 }
            // Measured once, then drawn at the height the panel asks for.
            for (appearance, _) in Self.appearances.prefix(1) {
                _ = try await render(AnswerPanelView(model: panel), size: CGSize(width: AnswerPanelController.width, height: 700),
                                     appearance: appearance, backdrop: true)
            }
            try await popup(name, size: CGSize(width: AnswerPanelController.width, height: max(height, 60))) { AnswerPanelView(model: panel) }
        }

        let shortcut = Hotkey(keyCode: 8, modifiers: 4096 | 512)
        let items = [
            BubbleItem(id: UUID(), title: "Explain", symbol: SelectionBubbleItems.answerSymbol, answers: true,
                       hotkey: Hotkey(keyCode: 14, modifiers: 4096 | 2048)),
            BubbleItem(id: UUID(), title: "Define", symbol: SelectionBubbleItems.answerSymbol, answers: true),
            BubbleItem(id: UUID(), title: "Proofread", symbol: SelectionBubbleItems.writingSymbol, answers: false, hotkey: shortcut),
            BubbleItem(id: UUID(), title: "Polish email", symbol: SelectionBubbleItems.writingSymbol, answers: false),
            BubbleItem(id: UUID(), title: "Translate to German", symbol: SelectionBubbleItems.writingSymbol, answers: false)
        ]
        let pointer = BubblePointer()
        try await popup("selection-bubble") {
            SelectionBubbleView(visible: Array(items.prefix(3)), more: Array(items.dropFirst(3)), expanded: false, pointer: pointer,
                                select: { _ in }, expand: {})
        }
        try await popup("selection-bubble-expanded") {
            SelectionBubbleView(visible: Array(items.prefix(3)), more: Array(items.dropFirst(3)), expanded: true, pointer: pointer,
                                select: { _ in }, expand: {})
        }
    }

    // MARK: Dictation

    private func dictation(root: URL) async throws {
        guard wanted("dictation-popup") else { return }
        try ConfigurationStore(directory: root).save(Configuration())
        let controller = DictationController(makeRecorder: { SampleRecording() }, authorize: { true }, copy: { _ in },
                                             monitorKeys: false, inputDevices: { [] }, presentsPopup: false)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil }, dictationController: controller,
                             systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
        defer { controller.cancel(); model.shutdown() }
        controller.externalTranscription = { _, _ in "" }
        controller.onInterruption = { _ in false }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture-speech"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false
        model.startDictation(rule)
        await controller.waitForWork()
        controller.updatePreview("Let's move the design review to Thursday afternoon, and send the new screenshots before then.")
        controller.refreshRecordingFeedback(elapsed: 14)
        let frame = DictationPopupLayout.frame(phase: controller.phase, text: controller.liveText,
                                               visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900))
        try await popup("dictation-popup", size: frame.size) { DictationPopup(controller: controller) }
    }

    // MARK: Notices

    private func notices(_ sample: SampleFrog) async throws {
        try await popup("notice-working") { ProcessingPill(symbol: nil, warning: false, text: "Working…") }
        let done = ProcessingIndicator.appearance(of: .done)
        try await popup("notice-done") { ProcessingPill(symbol: done.symbol, warning: false, text: done.text) }
        let failed = ProcessingIndicator.appearance(of: .failed("Ollama is not running."))
        try await popup("notice-failed") { ProcessingPill(symbol: failed.symbol, warning: true, text: failed.text, detail: failed.detail) }
        try await popup("notice-secure-input") {
            SecureInputPill(message: SecureInput.summary(SecureInput.Holder(pid: 1, name: "1Password", frontmost: false)))
        }
        try await popup("permission-drag-helper", size: PermissionDragHelper.panelSize) {
            PermissionDragHelperView(pane: .accessibility, url: URL(fileURLWithPath: "/Applications/Frog.app"),
                                     image: PermissionDragHelper.icon(bundled: false), open: {}, close: {})
                .frame(width: PermissionDragHelper.panelSize.width, height: PermissionDragHelper.panelSize.height)
        }
    }

    // MARK: Setup

    private func setup(_ sample: SampleFrog) async throws {
        for step in OnboardingView.Step.allCases {
            try await popup("setup-\(step.rawValue + 1)-\(step)") { OnboardingView(step: step.rawValue).environmentObject(sample.model) }
        }
    }

    // MARK: Sheets

    private func sheets(_ sample: SampleFrog) async throws {
        let model = sample.model
        try await sheet("sheet-plugin-settings") {
            PluginSettingsSheet(id: sample.focusTimerID, plugins: model.plugins, done: {}).environmentObject(model)
        }
        if wanted("sheet-plugin-review") {
            let item = try model.plugins.installFolder(sample.reviewPlugin)
            try model.plugins.reviewInstalled(item.id)
            if let review = model.plugins.review {
                try await sheet("sheet-plugin-review") { PluginReviewSheet(review: review, plugins: model.plugins, report: { _ in }) }
                model.plugins.dismissReview()
            }
        }
        if let cleaner = model.cleanerPlugin?.cleaner, wanted("sheet-cleaner-confirm") {
            if cleaner.review == nil { await cleaner.open(sample.cleanerApp); await cleaner.waitForSizes() }
            await cleaner.prepareRemoval()
            if let pending = cleaner.pending {
                try await sheet("sheet-cleaner-confirm") {
                    CleanerConfirmationSheet(pending: pending, cleaner: cleaner, roots: cleaner.dependencies.roots)
                }
                cleaner.cancelRemoval()
            }
        }
        try await sheet("sheet-provider-new") { ProviderEditor(provider: ProviderConfiguration()).environmentObject(model) }
        if let provider = model.configuration.providers.first {
            try await sheet("sheet-provider-edit") { ProviderEditor(provider: provider).environmentObject(model) }
        }
        if let rule = model.configuration.rules.first(where: { $0.category == .text && !$0.answersInPanel }) {
            try await sheet("sheet-writing-rule") { WritingRuleEditor(rule: rule, bubble: true) { _ in }.environmentObject(model) }
            try await sheet("sheet-writing-try") { WritingTryView(rule: rule).environmentObject(model) }
        }
        try await sheet("sheet-rename") { RenameSheet(name: "Dictate") { _ in } }
        if let item = LocalModelDescriptor.catalog.first {
            try await sheet("sheet-local-model-info") { LocalModelInformation(item: item) }
        }
        try await sheet("sheet-add-local-model") { AddLocalModelView { _ in }.environmentObject(model) }
        let legal = try sample.legalBundle()
        try await sheet("sheet-license") { LegalDocumentView(document: .license, bundle: legal) }
    }

    // MARK: Drawing

    private static let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]

    private func wanted(_ name: String) -> Bool {
        guard let only else { return true }
        return only.contains { name == $0 || name.hasPrefix($0) }
    }

    /// A page of the window, on the window's canvas, 1000 × 760 like the window's default size or `width` for a page column.
    private func page<Content: View>(_ name: String, width: CGFloat = 1_000, height: CGFloat = 760, settle: Duration = .milliseconds(400),
                                     _ view: () -> Content) async throws {
        guard wanted(name) else { return }
        for (appearance, mode) in Self.appearances {
            let png = try await render(view().frame(width: width, height: height).background(FrogStyle.opaqueCanvas),
                                       size: CGSize(width: width, height: height), appearance: appearance, backdrop: false, settle: settle)
            try write(png, "\(name)-\(mode)")
        }
    }

    /// A popup, panel or sheet at the size the app gives it, or its own fitting size, on a plain backdrop so its edge shows.
    private func popup<Content: View>(_ name: String, size: CGSize? = nil, _ view: () -> Content) async throws {
        guard wanted(name) else { return }
        for (appearance, mode) in Self.appearances {
            let content = view()
            let png: Data
            if let size {
                png = try await render(content.frame(width: size.width, height: size.height), size: size, appearance: appearance, backdrop: true)
            } else {
                png = try await render(content, size: nil, appearance: appearance, backdrop: true)
            }
            try write(png, "\(name)-\(mode)")
        }
    }

    /// A sheet: its own window, so it lies on the window's canvas with the window's corners.
    private func sheet<Content: View>(_ name: String, _ view: () -> Content) async throws {
        let content = view()
        try await popup(name) {
            content.background(FrogStyle.opaqueCanvas, in: RoundedRectangle(cornerRadius: FrogStyle.windowRadius, style: .continuous))
        }
    }

    private func render<Content: View>(_ view: Content, size: CGSize?, appearance: NSAppearance.Name, backdrop: Bool,
                                       settle: Duration = .milliseconds(400)) async throws -> Data {
        let margin: CGFloat = backdrop ? 24 : 0
        let host = NSHostingView(rootView: view.padding(margin)
            .background(backdrop ? (appearance == .aqua ? Color(white: 0.86) : Color(white: 0.16)) : Color.clear))
        host.appearance = NSAppearance(named: appearance)
        func fit() {
            let fitting = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size.map { CGSize(width: $0.width + margin * 2, height: $0.height + margin * 2) }
                ?? CGSize(width: ceil(fitting.width), height: ceil(fitting.height)))
            host.layoutSubtreeIfNeeded()
        }
        fit()
        try await Task.sleep(for: settle)
        fit()
        XCTAssertGreaterThan(host.bounds.width, 1); XCTAssertGreaterThan(host.bounds.height, 1)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func write(_ png: Data, _ file: String) throws {
        try png.write(to: URL(fileURLWithPath: "\(folder)/\(file).png"))
        written.append(file)
    }
}

/// An isolated Frog with every feature on and something in each place: notes and scripts, clipboard copies on a private
/// pasteboard, History entries, a Codex log for LLM usage, a fake Applications folder for the cleaner, and the Focus
/// timer example installed without its menu-bar item or background page, so nothing appears on this Mac's screen.
@MainActor
private final class SampleFrog {
    let model: AppModel
    let usage: UsageDashboardModel
    let pasteboard: NSPasteboard
    let history: ClipboardHistoryStore
    let cleaner: CleanerFixture
    let cleanerApp: URL
    let root: URL
    let focusTimer: URL
    let focusTimerID = "xyz.beffa.frog.focus-timer"
    /// A second copy of the example under another id, which waits for review.
    let reviewPlugin: URL

    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    init(root: URL, defaults: UserDefaults) async throws {
        self.root = root
        var configuration = Configuration()
        for feature in FeatureID.allCases { configuration.preferences.setFeature(feature, enabled: true) }
        configuration.preferences.historyEnabled = true
        configuration.rules.append(.dictationPreset)
        configuration.providers = [ProviderConfiguration(name: "Ollama", kind: .ollama)]
        try ConfigurationStore(directory: root).save(configuration)
        try await UtilityDocumentStore(directory: root.appendingPathComponent("Toolkit")).save([
            UtilityDocument(kind: .note, title: "Email signature", text: "Best,\nAnna\n{{date}}", pastes: true),
            UtilityDocument(kind: .note, title: "Meeting notes", text: "# Standup\n- Ship the release\n- Update the website"),
            UtilityDocument(kind: .script, title: "Clean downloads", text: "find ~/Downloads -mtime +30 -delete")
        ], revision: 0)

        pasteboard = NSPasteboard(name: .init("frog-ui-shots-\(UUID().uuidString)"))
        history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        history.configure(enabled: true, automaticallyPoll: false)
        for text in ["brew install --cask frog", "Thanks, see you at 3!", "https://frog.beffa.xyz/docs/command-bar/",
                     "Meeting moved to Thursday", "func greet(_ name: String) -> String {\n    \"Hello, \\(name)\"\n}",
                     "git push origin main"] { history.recordCopiedText(text) }

        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        try Self.writeCodexLog(in: fixtures)
        usage = UsageDashboardModel(defaults: defaults, fixtureRoot: fixtures)
        var preferences = usage.preferences
        preferences.provider = "OpenAI"
        usage.updatePreferences(preferences)

        cleaner = try CleanerFixture()
        cleanerApp = try cleaner.app("Chatter", bundleID: "com.example.chatter", payload: 4_000_000)
        _ = try cleaner.app("Sketchbook", bundleID: "com.example.sketchbook", payload: 9_000_000)
        _ = try cleaner.app("Notebook", bundleID: "com.example.notebook", payload: 600_000)
        _ = try cleaner.item(.caches, "com.example.chatter", bytes: 2_000_000)
        _ = try cleaner.item(.applicationSupport, "Chatter", bytes: 800_000)
        _ = try cleaner.item(.preferences, "com.example.chatter.plist", bytes: 4_000)

        let usage = self.usage
        let toolkit = Toolkit(makeUsage: { usage }, showsUsageStatusItem: false)
        model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil }, readAccessibility: { true },
                         toolkit: toolkit, clipboardHistoryStore: history,
                         systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
        let fixtureRoot = cleaner.root
        model.cleanerDependencies = { .fake(root: fixtureRoot) }
        model.plugins.registryURL = nil
        await model.pluginHost.syncAndWait()
        usage.setAvailable(true)
        usage.refresh()
        // The Codex log is read in the background.
        try await Task.sleep(for: .seconds(2))

        // History: a writing result, an answer and a dictation.
        var answer = HistoryEntry(timestamp: Date().addingTimeInterval(-3_600), originalText: "Requests must be idempotent so that retries are safe.",
                                  processedText: "Doing it again changes nothing: a request sent twice has the same effect as one.",
                                  ruleName: "Explain", providerName: "OpenAI", model: "gpt-5-mini")
        answer.answer = AnswerRecord(context: nil, application: "Safari", source: nil, followUps: [])
        var dictated = HistoryEntry(timestamp: Date().addingTimeInterval(-86_400), originalText: "",
                                    processedText: "Remind me to send the invoice on Friday and book the train to Zurich.",
                                    ruleName: "Dictate", providerName: "Parakeet", model: "parakeet-ultra")
        dictated.category = .audio
        let entries = [
            HistoryEntry(timestamp: Date().addingTimeInterval(-120), originalText: "i think we should of shipped it yesterday",
                         processedText: "I think we should have shipped it yesterday.", ruleName: "Proofread", providerName: "Ollama", model: "llama3.2"),
            answer, dictated
        ]
        for entry in entries { _ = try model.historyStore.append(entry, preferences: model.configuration.preferences) }
        model.refreshHistory()

        // The Focus timer, approved without its menu-bar item and background page.
        let plugins = root.appendingPathComponent("plugin-sources", isDirectory: true)
        focusTimer = plugins.appendingPathComponent("focus-timer", isDirectory: true)
        reviewPlugin = plugins.appendingPathComponent("focus-timer-review", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.repository.appendingPathComponent("plugins/focus-timer"), to: focusTimer)
        try FileManager.default.copyItem(at: focusTimer, to: reviewPlugin)
        try Self.editManifest(in: focusTimer) { manifest in
            manifest["permissions"] = ["notifications", "hotkeys"]
            manifest["menubar"] = nil
        }
        try Self.editManifest(in: reviewPlugin) { $0["id"] = "com.example.focus-review" }
        // A folder install waits for the user's review; the sample approves it as the user would.
        try model.plugins.installFolder(focusTimer)
        try model.plugins.reviewInstalled(focusTimerID)
        try model.plugins.approve(try XCTUnwrap(model.plugins.review))
        await model.pluginHost.syncAndWait()
    }

    func stop() {
        model.shutdown()
        pasteboard.releaseGlobally()
        cleaner.remove()
    }

    /// A bundle holding Frog's licence, as the packaged app carries it.
    func legalBundle() throws -> Bundle {
        let folder = root.appendingPathComponent("legal", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let license = Self.repository.appendingPathComponent("LICENSE")
        let target = folder.appendingPathComponent("LICENSE.txt")
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: license, to: target) }
        return try XCTUnwrap(Bundle(url: folder))
    }

    private static func editManifest(in folder: URL, _ change: (inout [String: Any]) -> Void) throws {
        let file = folder.appendingPathComponent("plugin.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        change(&manifest)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: file)
    }

    /// A day of Codex sessions with the plan's limits, as Codex logs them.
    private static func writeCodexLog(in fixtures: URL) throws {
        let folder = fixtures.appendingPathComponent("codex/sessions/2026/11/06", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let format = ISO8601DateFormatter()
        func line(_ date: Date, _ type: String, _ payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["timestamp": format.string(from: date), "type": type, "payload": payload]) + Data("\n".utf8)
        }
        var data = try line(now.addingTimeInterval(-6 * 3_600), "session_meta", ["id": "sample-thread", "model_provider": "openai"])
        data += try line(now.addingTimeInterval(-6 * 3_600), "turn_context", ["model": "gpt-5.5", "model_provider": "openai"])
        var total = (input: 0, output: 0, cached: 0)
        for step in 0..<24 {
            let date = now.addingTimeInterval(Double(step - 24) * 900)
            let last = (input: 18_000 + step * 900, output: 2_400 + step * 70, cached: 12_000 + step * 400)
            total = (total.input + last.input, total.output + last.output, total.cached + last.cached)
            func usage(_ value: (input: Int, output: Int, cached: Int)) -> [String: Any] {
                ["input_tokens": value.input, "cached_input_tokens": value.cached, "output_tokens": value.output,
                 "reasoning_output_tokens": 0, "total_tokens": value.input + value.output]
            }
            let limits: [String: Any] = [
                "primary": ["used_percent": 20 + step * 2, "window_minutes": 300, "resets_at": now.addingTimeInterval(5_400).timeIntervalSince1970],
                "secondary": ["used_percent": 31 + step / 2, "window_minutes": 10_080, "resets_at": now.addingTimeInterval(3 * 86_400).timeIntervalSince1970],
                "plan_type": "plus"
            ]
            data += try line(date, "event_msg", ["type": "token_count", "rate_limits": limits,
                                                 "info": ["total_token_usage": usage(total), "last_token_usage": usage(last)]])
        }
        try data.write(to: folder.appendingPathComponent("rollout-2026-11-06T09-00-00-sample.jsonl"))
    }
}

@MainActor private final class SampleRecording: DictationRecording {
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws {
        samples((0..<16_000).map { Float(sin(Double($0) / 9)) * 0.2 })
    }
    func stop() {}
}

/// The pictures never show files from this Mac.
@MainActor private final class NoFileSearch: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) { receive([]) }
    func stop() {}
}
