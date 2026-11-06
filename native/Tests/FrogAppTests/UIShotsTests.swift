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
        // System monitor reads made-up figures, never this Mac's, and opens on ten minutes of graph.
        let makeSampler = SystemMonitorPlugin.makeSampler
        SystemMonitorPlugin.makeSampler = { SampleSystemSampler() }
        defer { SystemMonitorPlugin.makeSampler = makeSampler }
        let sample = try await SampleFrog(root: root, defaults: temporaryDefaults())
        (sample.model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)?.monitor?.restore(SampleSystemSampler.history())
        defer { sample.stop() }

        try await mainWindow(sample)
        try await menuBar(sample)
        try await keyboardPanels(sample)
        try await answerAndBubble(sample)
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
        // The app list is read once before the pages, so Shortcuts pictures the same state in light and dark.
        await ApplicationCatalogStore.shared.load()
        let routes: [(String, ToolkitRoute)] = FeatureID.allCases.map { ($0.rawValue, .feature($0)) }
            + [("history", .history), ("models", .models), ("features", .features), ("settings", .settings),
               ("statistics", .statistics)]
        for (route, value) in routes where wanted("page-\(route)") {
            model.toolkit.select(value)
            try await page("page-\(route)", settle: .milliseconds(500)) { MainView().environmentObject(model) }
        }
        // Behind an entry or a tab, drawn in the whole window like the other pages: sidebar, toolbar and breadcrumb.
        func step<Page: View>(_ name: String, _ route: ToolkitRoute, settle: Duration = .milliseconds(500),
                              _ content: () -> Page) async throws {
            model.toolkit.select(route)
            let page = AnyView(content().environmentObject(model))
            try await self.page(name, settle: settle) { MainView(pageOverride: page).environmentObject(model) }
        }
        if let entry = model.history.first {
            try await step("page-history-detail", .history) { HistoryView(viewing: entry.id) }
        }
        for (name, tab) in [("directory", PluginsTab.browse), ("build", .build)] {
            try await step("page-plugins-\(name)", .feature(.plugins)) { PluginsView(plugins: model.plugins, tab: tab) }
        }
        for (name, filter) in [("local", "Local models"), ("providers", "Providers"), ("tools", "Installed tools")] {
            // The coding tools answer one by one; every row has answered before the picture.
            try await step("page-models-\(name)", .models, settle: name == "tools" ? .seconds(4) : .milliseconds(500)) {
                ProvidersView(filter: filter)
            }
        }
        if let cleaner = model.cleanerPlugin?.cleaner, wanted("page-cleaner-review") {
            await cleaner.open(sample.cleanerApp)
            await cleaner.waitForSizes()
            // In the window, so the toolbar's "App cleaner › Name" breadcrumb is pictured too.
            model.toolkit.select(.feature(.cleaner))
            try await page("page-cleaner-review", settle: .milliseconds(500)) { MainView().environmentObject(model) }
            cleaner.closeReview()
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
        // What it shows in the moment before the first readings arrive.
        let waiting = SystemMonitor(sampler: StalledSystemSampler())
        defer { waiting.stop() }
        try await popup("popup-system-monitor-loading") { SystemMonitorStatusPopover(monitor: waiting) {} }
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
            // Transparent around its card, so the shell's panel shows through as it does on screen.
            let page = try await host.snapshot(onCanvas: false)
            host.stop()
            sample.model.plugins.popups[sample.focusTimerID] = nil
            // The page in the popup Frog draws around it: the header with the plugin's tile, and Close beneath.
            let menubar = try XCTUnwrap(package.manifest.menubar)
            let pageSize = PluginPopupLayout.pageSize(menubar)
            let image = try XCTUnwrap(NSImage(data: page))
            let shell = PluginPopupShell(name: package.manifest.name, symbol: menubar.symbol ?? package.manifest.displaySymbol,
                                         width: PluginPopupLayout.panelWidth(contentWidth: CGFloat(menubar.popupWidth)), hasPage: true, openPage: {}) {
                Image(nsImage: image).resizable().frame(width: pageSize.width, height: pageSize.height)
            }
            let png = try await render(shell, size: nil, appearance: appearance, backdrop: true)
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
        // macOS's own apps, so the rows show real icons as they do on a Mac.
        for (pid, path) in [(1, "/Applications/Safari.app"), (2, "/System/Applications/Notes.app"), (3, "/System/Applications/Utilities/Terminal.app"),
                            (4, "/System/Applications/Mail.app"), (5, "/System/Applications/Calendar.app")] where FileManager.default.fileExists(atPath: path) {
            switcher.icons[pid_t(pid)] = NSWorkspace.shared.icon(forFile: path)
        }
        switcher.shortcuts[2] = "⌥N"
        try await popup("window-switcher", size: WindowSwitcherLayout.size(windowCount: switcher.windows.count)) {
            WindowSwitcherOverlay(model: switcher, choose: { _ in }, hover: { _ in })
        }

        let picker = LayoutPickerPanel()
        // ⌃⌥← and ⌃⌥→ on the halves and ⌃⌥↩ on Maximize, so the tiles show their caps.
        picker.picker = LayoutPickerModel(hotkeys: [.leftHalf: Hotkey(keyCode: 123, modifiers: 4096 | 2048),
                                                    .rightHalf: Hotkey(keyCode: 124, modifiers: 4096 | 2048),
                                                    .maximize: Hotkey(keyCode: 36, modifiers: 4096 | 2048)])
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

    private func answerAndBubble(_ sample: SampleFrog) async throws {
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
            ("answer-panel-failed", session { $0.modelName = "qwen3:4b"; $0.modelLabel = "qwen3:4b · Ollama"; $0.fail("Ollama is not running. Start it and try again.") }, { $0.recovery = .retry })
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

        // The sample's own rules, as the bubble builds its items from them: Explain with the shortcut its page shows,
        // Define, and the Writing rules, each with its own glyph.
        let rules = sample.model.configuration.rules
        let names = ["Explain", "Define", "Proofread", "Polish email", "Translate to German"]
        let items = names.compactMap { name in rules.first { $0.name == name } }.map { rule in
            BubbleItem(id: rule.id, title: rule.name, symbol: SelectionBubbleItems.symbol(for: rule), answers: rule.answersInPanel,
                       hotkey: rule.hotkey)
        }
        let pointer = BubblePointer()
        try await popup("selection-bubble") {
            SelectionBubbleView(visible: Array(items.prefix(3)), more: Array(items.dropFirst(3)), expanded: false, pointer: pointer,
                                select: { _ in }, expand: {})
        }
        // The pointer over Define, so the list's hover is pictured too.
        let overDefine = BubblePointer()
        overDefine.location = CGPoint(x: 60, y: 76)
        try await popup("selection-bubble-expanded") {
            SelectionBubbleView(visible: Array(items.prefix(3)), more: Array(items.dropFirst(3)), expanded: true, pointer: overDefine,
                                select: { _ in }, expand: {})
        }
    }

    // MARK: Dictation

    private func dictation(root: URL) async throws {
        guard wanted("dictation-popup") else { return }
        // The recording reads 0:14 once it is under way, so the timer matches the sentence already transcribed.
        final class SampleClock { var started = false }
        let clock = SampleClock(), start = ContinuousClock.now
        try ConfigurationStore(directory: root).save(Configuration())
        let controller = DictationController(makeRecorder: { SampleRecording() }, authorize: { true }, copy: { _ in },
                                             monitorKeys: false, inputDevices: { [] },
                                             now: { start.advanced(by: clock.started ? .seconds(14) : .zero) }, presentsPopup: false)
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
        clock.started = true
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
        let failed = ProcessingIndicator.appearance(of: .failed("Ollama is not running."), rule: "Proofread")
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
            // Setup is a sheet on the main window; `sheet` clips it to the window's corners.
            try await sheet("setup-\(step.rawValue + 1)-\(step)") {
                OnboardingView(step: step.rawValue).environmentObject(sample.model)
            }
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

    /// A page of the window, on the window's canvas, at the size the window opens at (`MainView.defaultSize`) or
    /// `width` for a page column.
    private func page<Content: View>(_ name: String, width: CGFloat = MainView.defaultSize.width, height: CGFloat = MainView.defaultSize.height, settle: Duration = .milliseconds(400),
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

    /// A sheet: its own window, so it lies on the window's canvas and is clipped to the window's corners, as macOS
    /// clips a sheet's window. A sheet's own square background never shows past them.
    private func sheet<Content: View>(_ name: String, _ view: () -> Content) async throws {
        let content = view()
        let shape = RoundedRectangle(cornerRadius: FrogStyle.windowRadius, style: .continuous)
        try await popup(name) {
            content.background(FrogStyle.opaqueCanvas).clipShape(shape)
        }
    }

    private func render<Content: View>(_ view: Content, size: CGSize?, appearance: NSAppearance.Name, backdrop: Bool,
                                       settle: Duration = .milliseconds(400)) async throws -> Data {
        let margin: CGFloat = backdrop ? 24 : 0
        // Drawn as the front window draws: Frog's app is not active while the tests run.
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key).padding(margin)
            .background(backdrop ? (appearance == .aqua ? Color(white: 0.86) : Color(white: 0.16)) : Color.clear))
        host.appearance = NSAppearance(named: appearance)
        // In a window that is never shown, as the app's views are: scroll views only scroll to a row (the sidebar
        // showing the open page) inside one. It reports itself key, so controls draw as in the front window.
        let window = ShotWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.contentView = nil }
        func fit() {
            let fitting = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size.map { CGSize(width: $0.width + margin * 2, height: $0.height + margin * 2) }
                ?? CGSize(width: ceil(fitting.width), height: ceil(fitting.height)))
            window.setContentSize(host.frame.size)
            host.layoutSubtreeIfNeeded()
        }
        fit()
        // Nothing has keyboard focus, as in a window that has just opened before the user clicks: a text view that
        // took first responder here drew its insertion point as a stray dot at its top-left corner.
        window.makeFirstResponder(nil)
        try await Task.sleep(for: settle)
        fit()
        window.makeFirstResponder(nil)
        hideInsertionIndicators(in: host)
        XCTAssertGreaterThan(host.bounds.width, 1); XCTAssertGreaterThan(host.bounds.height, 1)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// An offscreen text view still draws its insertion indicator, a two-pixel accent dot at its top-left corner,
    /// though nothing has focus: a window that has just opened shows no caret, so the pictures hide it.
    private func hideInsertionIndicators(in view: NSView) {
        if let text = view as? NSTextView { text.insertionPointColor = .clear }
        if view is NSTextInsertionIndicator { view.isHidden = true }
        view.subviews.forEach(hideInsertionIndicators)
    }

    private func write(_ png: Data, _ file: String) throws {
        try png.write(to: URL(fileURLWithPath: "\(folder)/\(file).png"))
        written.append(file)
    }
}

/// A window that is never ordered in but says it is key, main and on screen, so a picture's controls are drawn
/// active and views that work only while seen (System monitor's readings) do.
private final class ShotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
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

    /// Coding tools of their own, so the Coding tools tab never probes this Mac's: Codex installed and signed in,
    /// Claude Code installed and signed out, OpenCode missing.
    private static func sampleTools(in folder: URL) throws -> LocalToolClient {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tools = [
            "codex": """
            case "$1" in
              --version) echo 'codex-cli 0.159.0' ;;
              exec) echo '--strict-config --ignore-user-config --ignore-rules --ephemeral --json' ;;
              login) echo 'Logged in using ChatGPT' ;;
            esac
            """,
            "claude": """
            case "$1" in
              --help) echo '--safe-mode --tools --strict-mcp-config --permission-prompts --setting-sources --no-session-persistence' ;;
              auth) echo '{"loggedIn": false}' ;;
            esac
            """
        ]
        for (name, body) in tools {
            let url = folder.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return LocalToolClient(discovery: .init(home: folder, environment: [:], searchDirectories: [folder]), temporaryRoot: folder)
    }

    init(root: URL, defaults: UserDefaults) async throws {
        self.root = root
        var configuration = Configuration()
        for feature in FeatureID.allCases { configuration.preferences.setFeature(feature, enabled: true) }
        configuration.preferences.historyEnabled = true
        configuration.rules.append(.dictationPreset)
        // Explain on ⌃⌥E, as someone who set its shortcut has it, and a second answer rule for the bubble.
        var explain = Rule.explainPreset
        explain.hotkey = Hotkey(keyCode: 14, modifiers: 4096 | 2048)
        var define = Rule(name: "Define", instructions: "Define the selected word in one sentence.")
        define.action = RuleAction(category: .text)
        define.action?.textOutput = .panel
        configuration.rules += [explain, define]
        // A few layouts with shortcuts, as the layout picker shows them, so Windows' grid pictures its recorded caps.
        let layouts: [(WindowAction, Hotkey)] = [(.leftHalf, Hotkey(keyCode: 123, modifiers: 4096 | 2048)),
                                                 (.rightHalf, Hotkey(keyCode: 124, modifiers: 4096 | 2048)),
                                                 (.maximize, Hotkey(keyCode: 36, modifiers: 4096 | 2048)),
                                                 (.previousDisplay, Hotkey(keyCode: 123, modifiers: 4096 | 2048 | 256))]
        for (action, hotkey) in layouts {
            var rule = action.rule
            rule.hotkey = hotkey; rule.enabled = true
            configuration.rules.append(rule)
        }
        configuration.providers = [ProviderConfiguration(name: "Ollama", kind: .ollama)]
        try ConfigurationStore(directory: root).save(configuration)
        // Changed at different times, so the lists' times say something.
        let now = Date()
        try await UtilityDocumentStore(directory: root.appendingPathComponent("Toolkit")).save([
            UtilityDocument(kind: .note, title: "Email signature", text: "Best,\nAnna\n{{date}}", modified: now.addingTimeInterval(-3 * 86_400), pastes: true),
            UtilityDocument(kind: .note, title: "Meeting notes", text: "# Standup\n- Ship the release\n- Update the website", modified: now.addingTimeInterval(-25 * 60)),
            UtilityDocument(kind: .script, title: "Clean downloads", text: "find ~/Downloads -mtime +30 -delete", modified: now.addingTimeInterval(-26 * 3_600))
        ], revision: 0)

        pasteboard = NSPasteboard(name: .init("frog-ui-shots-\(UUID().uuidString)"))
        history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        history.configure(enabled: true, automaticallyPoll: false)
        // Copied over the last few days, oldest first, so the times down the list differ as they would.
        let copies: [(String, TimeInterval)] = [
            ("brew install --cask frog", 4 * 86_400), ("Thanks, see you at 3!", 27 * 3_600),
            ("https://frog.beffa.xyz/docs/command-bar/", 3 * 3_600), ("Meeting moved to Thursday", 47 * 60),
            ("func greet(_ name: String) -> String {\n    \"Hello, \\(name)\"\n}", 12 * 60), ("git push origin main", 20)
        ]
        for (text, ago) in copies { history.recordCopiedText(text, at: now.addingTimeInterval(-ago)) }

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
                         localToolClient: try Self.sampleTools(in: root.appendingPathComponent("Tools", isDirectory: true)),
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

    /// A week of Codex sessions, heavier on some days than others, with the plan's limits as Codex logs them: the
    /// activity chart pictures a working week, not a single day's spike.
    private static func writeCodexLog(in fixtures: URL) throws {
        let now = Date()
        let format = ISO8601DateFormatter()
        let calendar = Calendar(identifier: .gregorian)
        func line(_ date: Date, _ type: String, _ payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["timestamp": format.string(from: date), "type": type, "payload": payload]) + Data("\n".utf8)
        }
        func usage(_ value: (input: Int, output: Int, cached: Int)) -> [String: Any] {
            ["input_tokens": value.input, "cached_input_tokens": value.cached, "output_tokens": value.output,
             "reasoning_output_tokens": 0, "total_tokens": value.input + value.output]
        }
        // Turns per day, oldest first; today is the last.
        let turns = [14, 9, 0, 18, 11, 21, 24]
        for (index, count) in turns.enumerated() where count > 0 {
            let daysAgo = turns.count - 1 - index
            let end = daysAgo == 0 ? now.addingTimeInterval(-15 * 60) : calendar.date(byAdding: .day, value: -daysAgo, to: now)!.addingTimeInterval(-3 * 3_600)
            let parts = calendar.dateComponents([.year, .month, .day], from: end)
            let folder = fixtures.appendingPathComponent(String(format: "codex/sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let begin = end.addingTimeInterval(-Double(count) * 900)
            var data = try line(begin, "session_meta", ["id": "sample-thread-\(index)", "model_provider": "openai"])
            data += try line(begin, "turn_context", ["model": "gpt-5.5", "model_provider": "openai"])
            var total = (input: 0, output: 0, cached: 0)
            for step in 0..<count {
                let date = begin.addingTimeInterval(Double(step + 1) * 900)
                let last = (input: 18_000 + step * 900, output: 2_400 + step * 70, cached: 12_000 + step * 400)
                total = (total.input + last.input, total.output + last.output, total.cached + last.cached)
                let limits: [String: Any] = [
                    "primary": ["used_percent": 20 + step * 2, "window_minutes": 300, "resets_at": now.addingTimeInterval(5_400).timeIntervalSince1970],
                    "secondary": ["used_percent": 31 + step / 2, "window_minutes": 10_080, "resets_at": now.addingTimeInterval(3 * 86_400).timeIntervalSince1970],
                    "plan_type": "plus"
                ]
                data += try line(date, "event_msg", ["type": "token_count", "rate_limits": limits,
                                                     "info": ["total_token_usage": usage(total), "last_token_usage": usage(last)]])
            }
            try data.write(to: folder.appendingPathComponent("rollout-\(index)-sample.jsonl"))
        }
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

/// Made-up readings for System monitor's pictures: a Mac on battery under light load.
private struct SampleSystemSampler: SystemMonitorSampling {
    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot {
        var power = SystemMonitorPower()
        power.source = "Battery"; power.batteryPercent = 78; power.thermal = "Nominal"; power.lowPower = false
        power.batteryFlow = .drawing(watts: 9.4); power.systemWatts = 11.2; power.batteryCelsius = 31
        return SystemMonitorSnapshot(cpu: .value(0.24), gpu: .value(0.11),
                                     memory: SystemMonitorMemory(used: 11_400_000_000, total: 17_179_869_184),
                                     storage: SystemMonitorStorage(available: 182_000_000_000, total: 494_000_000_000), power: power)
    }

    /// Ten minutes of graph, a reading every ten seconds, with a short burst of work in the middle.
    static func history(now: Date = Date()) -> [SystemMonitorSample] {
        (0..<60).map { index in
            let t = Double(index)
            let burst = max(0, 1 - abs(t - 34) / 6) * 0.45
            let cpu = 0.14 + 0.06 * sin(t / 3) + 0.03 * sin(t * 1.7) + burst
            let gpu = 0.07 + 0.03 * sin(t / 5 + 1) + burst * 0.5
            return SystemMonitorSample(time: now.addingTimeInterval(-600 + t * 10), cpu: cpu, gpu: gpu, memory: 0.64 + 0.02 * sin(t / 9))
        }
    }
}

/// A sampler whose first reading never comes, for the loading picture.
private struct StalledSystemSampler: SystemMonitorSampling {
    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot {
        try? await Task.sleep(for: .seconds(3_600))
        return SystemMonitorSnapshot()
    }
}
