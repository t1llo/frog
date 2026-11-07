import XCTest
import AppKit
import SwiftUI
import FrogCore
import FrogTestSupport
@testable import FrogUsage
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
        // Every time the pictures show (resets, "ago", "Until", chart ranges, the sample data's own dates) reads one
        // fixed clock, so two runs draw the same pictures.
        let previousNow = getenv(FrogClock.variable).map { String(cString: $0) }
        setenv(FrogClock.variable, Self.fixedNow, 1)
        defer { if let previousNow { setenv(FrogClock.variable, previousNow, 1) } else { unsetenv(FrogClock.variable) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frog-ui-shots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // System monitor reads made-up figures, never this Mac's, and opens on ten minutes of graph.
        let makeSampler = SystemMonitorPlugin.makeSampler
        SystemMonitorPlugin.makeSampler = { SampleSystemSampler() }
        defer { SystemMonitorPlugin.makeSampler = makeSampler }
        // A shipped version, as Settings and About show it in the app, never the test bundle's.
        FrogVersion.override = ("1.0.48", "48")
        defer { FrogVersion.override = nil }
        let sample = try await SampleFrog(root: root, defaults: temporaryDefaults())
        (sample.model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)?.monitor?.restore(SampleSystemSampler.history(now: FrogClock.now))
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

    /// The time of every picture: 2026-11-07 13:40 in this Mac's time zone, an afternoon.
    static let fixedNow = "2026-11-07T13:40:00"

    // MARK: The window

    private func mainWindow(_ sample: SampleFrog) async throws {
        let model = sample.model
        // The app list is read once before the pages, so Shortcuts pictures the same state in light and dark.
        await ApplicationCatalogStore.shared.load()
        let routes: [(String, ToolkitRoute)] = FeatureID.allCases.map { ($0.rawValue, .feature($0)) }
            + [("history", .history), ("models", .models), ("features", .features), ("settings", .settings),
               ("statistics", .statistics)]
        // The pages show the sidebar someone has after setup: the features Frog starts with, the ones setup
        // recommends and the community plugin, plus the page's own feature when it is not one of those. The menus,
        // panels and popups after the window keep every feature on.
        let everyFeature = model.configuration.preferences
        for (route, value) in routes where wanted("page-\(route)") {
            if case .feature(let feature) = value { try await sample.useRealisticFeatures(plus: feature) }
            else { try await sample.useRealisticFeatures(plus: nil) }
            if route == "cleaner", let cleaner = model.cleanerPlugin?.cleaner {
                // The finished scan, sizes and all, as the page looks once it has loaded.
                await cleaner.loadApps()
                await cleaner.measureAppSizes()
            }
            model.toolkit.select(value)
            try await page("page-\(route)", settle: .milliseconds(500)) { MainView().environmentObject(model) }
        }
        try await sample.useRealisticFeatures(plus: nil)
        // Behind an entry or a tab, drawn in the whole window like the other pages: sidebar, toolbar and breadcrumb.
        func step<Page: View>(_ name: String, _ route: ToolkitRoute, settle: Duration = .milliseconds(500),
                              _ content: () -> Page) async throws {
            model.toolkit.select(route)
            let page = AnyView(content().environmentObject(model))
            try await self.page(name, settle: settle) { MainView(pageOverride: page).environmentObject(model) }
        }
        if wanted("page-search") {
            // The sidebar's search finding settings on every page, and the page a result opens, scrolled to it.
            try await sample.useRealisticFeatures(plus: .systemMonitor)
            model.toolkit.select(.features)
            try await page("page-search-results", settle: .milliseconds(500)) { MainView(query: "menu").environmentObject(model) }
            model.toolkit.select(.settings)
            let focus = FrogSearchFocus(route: .settings, section: "Updates", row: "Check automatically")
            try await page("page-search-opened", settle: .milliseconds(700)) { MainView(focus: focus).environmentObject(model) }
            try await sample.useRealisticFeatures(plus: nil)
        }
        if let entry = model.history.first {
            try await step("page-history-detail", .history) { HistoryView(viewing: entry.id) }
        }
        if wanted("page-statistics-data") {
            // Statistics with counts, as after some weeks of use: its own store in the sample's folder, never this Mac's.
            let statistics = ActivityStatisticsStore(directory: sample.root.appendingPathComponent("statistics-data", isDirectory: true))
            statistics.setRecordingEnabled(true)
            for index in 0..<42 {
                statistics.recordDictation(recordingSeconds: Double(8 + index % 23), text: String(repeating: "word ", count: 18 + index % 31),
                                           rule: .dictation)
            }
            for (offset, kind) in ActivityRuleKind.allCases.enumerated() {
                for _ in 0..<[27, 19, 6, 42, 11, 8, 3][offset % 7] { statistics.recordRuleExecution(kind: kind) }
            }
            for (offset, kind) in ActivityToolKind.allCases.enumerated() {
                for _ in 0..<((offset * 7) % 19) { statistics.recordToolUse(kind) }
            }
            statistics.waitForWrites()
            // With the Settings › Statistics breadcrumb, as MainView shows the page.
            try await step("page-statistics-data", .statistics) {
                StatisticsView(statistics: statistics).frogPageBack("statistics", parent: "Settings") {}
            }
        }
        if wanted("page-scripts-output") {
            // A script just run, its output folded open under it: its own documents and runner in the sample's folder,
            // and a script that only prints, so nothing on this Mac changes.
            try await sample.useRealisticFeatures(plus: .scripts)
            let documents = LocalDocuments(directory: sample.root.appendingPathComponent("scripts-output", isDirectory: true))
            await documents.load()
            let script = UtilityDocument(kind: .script, title: "Morning check",
                                         text: "echo \"Good morning\"\necho \"3 updates waiting\"\necho \"Backup finished at 06:00\"",
                                         modified: FrogClock.now)
            documents.add(script)
            documents.selection[.script] = script.id
            let runner = ScriptRunner()
            runner.run(script, timeout: 10)
            for _ in 0..<100 where runner.running != nil { try await Task.sleep(for: .milliseconds(50)) }
            try await step("page-scripts-output", .feature(.scripts)) {
                ScriptsPage(documents: documents, runner: runner, timeout: 60, run: { _ in }, setTimeout: { _ in })
            }
            try await sample.useRealisticFeatures(plus: nil)
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
        if wanted("page-cleaner-review") { try await sample.useRealisticFeatures(plus: .cleaner) }
        if let cleaner = model.cleanerPlugin?.cleaner, wanted("page-cleaner-review") {
            await cleaner.open(sample.cleanerApp)
            await cleaner.waitForSizes()
            // In the window, so the toolbar's "App cleaner › Name" breadcrumb is pictured too.
            model.toolkit.select(.feature(.cleaner))
            try await page("page-cleaner-review", settle: .milliseconds(500)) { MainView().environmentObject(model) }
            cleaner.closeReview()
        }
        // The moment before the app list arrives: a cleaner whose catalogue never answers, so its skeleton stays.
        if let cleaner = model.cleanerPlugin?.cleaner, wanted("page-cleaner-loading") {
            try await sample.useRealisticFeatures(plus: .cleaner)
            var dependencies = cleaner.dependencies
            dependencies.applications = {
                try? await Task.sleep(for: .seconds(3600))
                return []
            }
            let loading = CleanerModel(dependencies: dependencies)
            let load = Task { await loading.loadApps() }
            defer { load.cancel() }
            try await step("page-cleaner-loading", .feature(.cleaner)) {
                CleanerView(cleaner: loading) { _ in }
            }
        }
        try await hiddenBarSections(sample)
        try await sample.useFeatures(everyFeature)
    }

    /// Hidden bar's page with its picture of the menu bar, which it shows only beside a running organizer: one with
    /// status items that never reach this Mac's menu bar, and the always-hidden section on, so both dividers show.
    /// Afterwards Hidden bar runs again as before, without an organizer.
    private func hiddenBarSections(_ sample: SampleFrog) async throws {
        guard wanted("page-hiddenBar-sections") else { return }
        let model = sample.model
        var on = model.configuration.preferences, off = on
        on.setFeature(.menuBar, enabled: true)
        off.setFeature(.menuBar, enabled: false)
        // The section is on before the organizer starts, as after a restart: turned on beside a running organizer,
        // it would open the page arranging.
        try await sample.useFeatures(on)
        var plugin = try XCTUnwrap(model.pluginHost.running["hidden-bar"] as? HiddenBarPlugin)
        let alwaysHidden = plugin.settings.alwaysHiddenSection
        plugin.update { $0.alwaysHiddenSection = true }
        try await sample.useFeatures(off)
        HiddenBarPlugin.makeOrganizer = {
            MenuBarOrganizer(statusItems: ShotStatusItems(), applications: ShotApplications(), automaticTicks: false, environment: {
                OrganizerEnvironment(screens: [OrganizerScreen(frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                                                               menuRegions: [CGRect(x: 0, y: 876, width: 1_440, height: 24)])])
            })
        }
        defer { HiddenBarPlugin.makeOrganizer = nil }
        try await sample.useFeatures(on)
        plugin = try XCTUnwrap(model.pluginHost.running["hidden-bar"] as? HiddenBarPlugin)
        model.toolkit.select(.feature(.menuBar))
        try await page("page-hiddenBar-sections", settle: .milliseconds(500)) { MainView().environmentObject(model) }
        plugin.update { $0.alwaysHiddenSection = alwaysHidden }
        try await sample.useFeatures(off)
    }

    // MARK: The menu bar

    /// Two Claude accounts on the Max plan, read a moment and three minutes ago.
    static func sampleAccounts(now: Date) -> [UsageAccountSummary] {
        func account(_ label: String, session: Double, sessionReset: TimeInterval, week: Double, weekReset: TimeInterval, age: TimeInterval) -> UsageAccountSummary {
            UsageAccountSummary(
                id: "/sample/\(label)", label: label, shortLabel: label,
                windows: [UsageWindow(id: "five_hour", title: "Session", percentage: session,
                                      resetsAt: session.isFinite ? now.addingTimeInterval(sessionReset) : nil, duration: 5 * 3600),
                          UsageWindow(id: "seven_day", title: "Week", percentage: week,
                                      resetsAt: now.addingTimeInterval(weekReset), duration: 7 * 86_400)],
                plan: "Max 20×", sources: ["Claude app · Claude-Account-\(label)"], age: now.addingTimeInterval(-age),
                readingSource: "Claude app", stale: false, status: nil, included: true,
                needsLiveSetup: false, mergedNote: nil)
        }
        return [account("A", session: 37, sessionReset: 2 * 3600, week: 52, weekReset: 5 * 86_400, age: 20),
                account("B", session: .nan, sessionReset: 0, week: 57, weekReset: 4 * 86_400, age: 180)]
    }

    private func menuBar(_ sample: SampleFrog) async throws {
        let model = sample.model
        try await popup("menu-frog") { FrogStatusMenu(model: model).environment(\.locale, L10n.locale) }
        for tab in model.pluginHost.menuTabs {
            let name = tab.id.hasSuffix(".tab") ? String(tab.id.dropLast(4)) : tab.id
            try await popup("menu-\(name)") { FrogStatusMenu(model: model, tab: tab.id).environment(\.locale, L10n.locale) }
        }
        try await popup("popup-llm-usage") { UsageStatusPopover(usage: sample.usage, openDashboard: {}) }
        // Two Claude accounts, as a Mac signed in to two reads them: B's session renewed after its last reading.
        // The accounts are Claude's, so the popup is on Claude, as it is whenever it shows them.
        let shown = sample.usage.preferences
        var claude = shown
        claude.provider = "Claude"
        sample.usage.updatePreferences(claude)
        try await popup("popup-llm-usage-accounts") {
            UsageStatusPopover(usage: sample.usage, openDashboard: {}, sampleAccounts: Self.sampleAccounts(now: FrogClock.now))
        }
        sample.usage.updatePreferences(shown)
        if let monitor = (model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)?.monitor {
            try await popup("popup-system-monitor") { SystemMonitorStatusPopover(monitor: monitor) {} }
        }
        // What it shows in the moment before the first readings arrive.
        let waiting = SystemMonitor(sampler: StalledSystemSampler())
        defer { waiting.stop() }
        // A Mac with a battery, as the loaded popup pictures one, so the skeleton holds the battery card's place.
        let hadBattery = PowerSources.hasInternalBattery
        PowerSources.hasInternalBattery = true
        defer { PowerSources.hasInternalBattery = hadBattery }
        try await popup("popup-system-monitor-loading") { SystemMonitorStatusPopover(monitor: waiting) {} }
        // The pages' Menu bar sections on their own, switched on so the style and colour pickers show.
        if let plugin = model.pluginHost.running["llm-usage"] as? LLMUsagePlugin {
            try await section("picker-llm-usage-menubar") { UsageMenuBarSection(plugin: plugin, usage: sample.usage) }
        }
        if let plugin = model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin {
            var settings = plugin.settings
            settings.menuBarItem = true
            try await section("picker-system-monitor-menubar") { SystemMonitorMenuBarSection(settings: settings) { _ in } }
        }
        try await popup("menubar-items") { MenuBarItemsPicture(usage: sample.usage) }
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
            // The running app's icon, as the switcher reads it: no alias arrow from Safari's symlink in /Applications.
            switcher.icons[pid_t(pid)] = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        // Apps given a shortcut in Shortcuts show it; a person who uses them has several, not one.
        switcher.shortcuts[1] = "⌥S"
        switcher.shortcuts[2] = "⌥N"
        switcher.shortcuts[3] = "⌥T"
        switcher.shortcuts[4] = "⌥M"
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
        // Held-key panels grow as tall as the display allows: here a 13-inch laptop's, less the panel's margin.
        let heldPanelLimit: CGFloat = 820
        let cheatHeight = min(heldPanelLimit,
                              ceil(NSHostingView(rootView: WindowCheatSheetContent(sections: sections).frame(width: WindowCheatSheetPanel.width)).fittingSize.height))
        try await popup("window-cheat-sheet") { WindowCheatSheetView(sections: sections, height: cheatHeight) }

        let groups = model.shortcutReferenceGroups
        let referenceHeight = min(heldPanelLimit,
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
                                select: { _ in }, expand: {}, editRules: {})
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
        // Fourteen seconds in, the meter holds the last four seconds of speech: syllables with short pauses
        // between words, across its whole width.
        for tick in 0..<40 {
            let syllable = abs(sin(Double(tick) * 1.7)) * (tick % 9 == 8 ? 0.1 : 1)
            controller.microphoneMeter.append(0.25 + 0.6 * syllable)
        }
        let frame = DictationPopupLayout.frame(phase: controller.phase, text: controller.liveText,
                                               visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900))
        try await popup("dictation-popup", size: frame.size) { DictationPopup(controller: controller) }
    }

    // MARK: Notices

    private func notices(_ sample: SampleFrog) async throws {
        try await popup("notice-working") { ProcessingPill(symbol: nil, text: ProcessingIndicator.workingText(rule: "Proofread")) }
        let done = ProcessingIndicator.appearance(of: .done, rule: "Proofread", summary: "3 words changed")
        try await popup("notice-done") { ProcessingPill(symbol: done.symbol, tone: done.tone, text: done.text, detail: done.detail) }
        let failed = ProcessingIndicator.appearance(of: .failed("Ollama is not running."), rule: "Proofread")
        try await popup("notice-failed") { ProcessingPill(symbol: failed.symbol, tone: failed.tone, text: failed.text, action: failed.detail.map { ($0, {}) }) }
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
            // As the Providers page opens a saved provider: on its second step, the connection.
            try await sheet("sheet-provider-edit") { ProviderEditor(provider: provider, step: 1).environmentObject(model) }
        }
        if let rule = model.configuration.rules.first(where: { $0.category == .text && !$0.answersInPanel }) {
            try await sheet("sheet-writing-rule") { WritingRuleEditor(rule: rule, bubble: true) { _ in }.environmentObject(model) }
            try await sheet("sheet-writing-try") { WritingTryView(rule: rule).environmentObject(model) }
        }
        try await sheet("sheet-rename") { RenameSheet(name: "Dictation", kind: "dictation rule") { _ in } }
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

    /// The window size the pages are drawn at: the size the window opens at (`MainView.defaultSize`), or
    /// `FROG_UI_SHOTS_SIZE` ("800x520") to picture a smaller window.
    private nonisolated static let windowSize: CGSize = {
        let parts = ProcessInfo.processInfo.environment["FROG_UI_SHOTS_SIZE"]?.split(separator: "x").compactMap { Double($0) }
        guard let parts, parts.count == 2 else { return MainView.defaultSize }
        return CGSize(width: parts[0], height: parts[1])
    }()

    /// A page of the window, on the window's canvas, at `windowSize` or `width` for a page column.
    private func page<Content: View>(_ name: String, width: CGFloat = windowSize.width, height: CGFloat = windowSize.height, settle: Duration = .milliseconds(400),
                                     _ view: () -> Content) async throws {
        guard wanted(name) else { return }
        for (appearance, mode) in Self.appearances {
            let png = try await render(view().frame(width: width, height: height).background(FrogStyle.opaqueCanvas)
                                        .overlay(alignment: .topLeading) { WindowButtonsPicture() },
                                       size: CGSize(width: width, height: height), appearance: appearance, backdrop: false, settle: settle)
            try write(png, "\(name)-\(mode)")
        }
    }

    /// One section of a page, as tall as it is, at the width of the page's column in the window (the window beside
    /// MainView's 208-point sidebar, less the page's padding, no wider than `FrogStyle.pageWidth`), on the window's
    /// canvas with the page's padding around it.
    private func section<Content: View>(_ name: String, _ view: () -> Content) async throws {
        guard wanted(name) else { return }
        let width = min(FrogStyle.pageWidth, Self.windowSize.width - 208 - FrogStyle.pagePadding * 2)
        for (appearance, mode) in Self.appearances {
            let png = try await render(view().frame(width: width, alignment: .leading).padding(FrogStyle.pagePadding)
                                        .background(FrogStyle.opaqueCanvas),
                                       size: nil, appearance: appearance, backdrop: false)
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
        let now = FrogClock.now
        // A phone paired a while ago and out of reach now, with the long name the menu row has to fit.
        try Self.writePairedPhone(in: root)
        try await UtilityDocumentStore(directory: root.appendingPathComponent("Toolkit")).save([
            UtilityDocument(kind: .note, title: "Email signature", text: "Best,\nAnna\n{{date}}", modified: now.addingTimeInterval(-3 * 86_400), pastes: true),
            UtilityDocument(kind: .note, title: "Meeting notes", text: "# Standup\n- Ship the release\n- Update the website", modified: now.addingTimeInterval(-25 * 60)),
            UtilityDocument(kind: .script, title: "Clean downloads", text: "find ~/Downloads -mtime +30 -delete", modified: now.addingTimeInterval(-26 * 3_600))
        ], revision: 0)

        pasteboard = NSPasteboard(name: .init("frog-ui-shots-\(UUID().uuidString)"))
        history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        history.configure(enabled: true, automaticallyPoll: false)
        // Copied over the last few days, oldest first, so the times down the list differ as they would.
        // Each in the app it would come from, as the rows and the preview name it.
        let copies: [(String, TimeInterval, String)] = [
            ("brew install --cask frog", 4 * 86_400, "Terminal"), ("Thanks, see you at 3!", 27 * 3_600, "Messages"),
            ("https://frog.beffa.xyz/docs/command-bar/", 3 * 3_600, "Safari"), ("Meeting moved to Thursday", 47 * 60, "Mail"),
            ("func greet(_ name: String) -> String {\n    \"Hello, \\(name)\"\n}", 12 * 60, "Xcode"), ("git push origin main", 20, "Terminal")
        ]
        for (text, ago, app) in copies { history.recordCopiedText(text, at: now.addingTimeInterval(-ago), source: app) }

        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        try Self.writeCodexLog(in: fixtures)
        usage = UsageDashboardModel(defaults: defaults, fixtureRoot: fixtures)
        var preferences = usage.preferences
        preferences.provider = "OpenAI"
        usage.updatePreferences(preferences)

        cleaner = try CleanerFixture()
        // Real system apps lend their icons, so the cleaner pictures app icons rather than blank bundles.
        func icon(_ app: String) -> URL { URL(fileURLWithPath: "/System/Applications/\(app).app/Contents/Resources/AppIcon.icns") }
        cleanerApp = try cleaner.app("Chatter", bundleID: "com.example.chatter", payload: 4_000_000, icon: icon("Stickies"))
        _ = try cleaner.app("Sketchbook", bundleID: "com.example.sketchbook", payload: 9_000_000, icon: icon("Preview"))
        _ = try cleaner.app("Notebook", bundleID: "com.example.notebook", payload: 600_000, icon: icon("Chess"))
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
        var answer = HistoryEntry(timestamp: now.addingTimeInterval(-3_600), originalText: "Requests must be idempotent so that retries are safe.",
                                  processedText: "Doing it again changes nothing: a request sent twice has the same effect as one.",
                                  ruleName: "Explain", providerName: "OpenAI", model: "gpt-5-mini")
        answer.answer = AnswerRecord(context: nil, application: "Safari", source: nil, followUps: [])
        var dictated = HistoryEntry(timestamp: now.addingTimeInterval(-86_400), originalText: "",
                                    processedText: "Remind me to send the invoice on Friday and book the train to Zurich.",
                                    ruleName: "Dictation", providerName: "Parakeet", model: "parakeet-ultra")
        dictated.category = .audio
        let entries = [
            HistoryEntry(timestamp: now.addingTimeInterval(-120), originalText: "i think we should of shipped it yesterday",
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

    /// The features someone has after setup: the ones Frog starts with, the ones setup recommends, and Plugins
    /// for the community plugin; `extra` as well when given.
    func realisticFeatures(plus extra: FeatureID?) -> Set<FeatureID> {
        let infos = model.pluginHost.descriptors.map(\.info)
        var features = Set(FeatureID.allCases.filter { feature in
            infos.first { $0.id == BuiltinPlugins.pluginID(for: feature) }.map { $0.enabledByDefault || $0.recommended } ?? false
        })
        features.insert(.plugins)
        if let extra { features.insert(extra) }
        return features
    }

    func useRealisticFeatures(plus extra: FeatureID?) async throws {
        let wanted = realisticFeatures(plus: extra)
        var preferences = model.configuration.preferences
        for feature in FeatureID.allCases { preferences.setFeature(feature, enabled: wanted.contains(feature)) }
        try await useFeatures(preferences)
    }

    /// Saves the features of `preferences` when they differ and waits for the plugins to follow. System monitor
    /// starts again on its ten minutes of made-up graph.
    func useFeatures(_ preferences: Preferences) async throws {
        let current = model.configuration.preferences
        guard FeatureID.allCases.contains(where: { current.featureEnabled($0) != preferences.featureEnabled($0) }) else { return }
        var next = current
        for feature in FeatureID.allCases { next.setFeature(feature, enabled: preferences.featureEnabled(feature)) }
        try model.savePreferences(next)
        await model.pluginHost.syncAndWait()
        (model.pluginHost.running["system-monitor"] as? SystemMonitorPlugin)?.monitor?.restore(SampleSystemSampler.history(now: FrogClock.now))
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

    /// "OPPO Find X9 Pro", paired five days ago and offline: Phone's pairing file in the sample's folder, as the app
    /// writes it. Its secret is never needed, as the sample opens no connection.
    static func writePairedPhone(in root: URL) throws {
        let paired = FrogClock.now.addingTimeInterval(-5 * 86_400)
        let json = """
        {"macID": "6F3C1A52-2B7E-4D0A-9C41-8E5B7D2F1A90", "phones": [{"id": "0B7E9C14-5A3D-4F21-8B6C-2D9E4A7F3C15", \
        "name": "OPPO Find X9 Pro", "pairedAt": "\(ISO8601DateFormatter().string(from: paired))"}]}
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: PhonePairingStore.defaultFile(in: root))
    }

    /// A week of Codex sessions, heavier on some days than others, with the plan's limits as Codex logs them: the
    /// activity chart pictures a working week, not a single day's spike.
    private static func writeCodexLog(in fixtures: URL) throws {
        let now = FrogClock.now
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
                                     storage: SystemMonitorStorage(available: 182_000_000_000, total: 494_000_000_000,
                                                                  availableDayAgo: 185_400_000_000), power: power)
    }

    /// Ten minutes of graph, a reading every ten seconds, with a short burst of work in the middle.
    static func history(now: Date = FrogClock.now) -> [SystemMonitorSample] {
        (0..<60).map { index in
            let t = Double(index)
            let burst = max(0, 1 - abs(t - 34) / 6) * 0.45
            let cpu = 0.14 + 0.06 * sin(t / 3) + 0.03 * sin(t * 1.7) + burst
            let gpu = 0.07 + 0.03 * sin(t / 5 + 1) + burst * 0.5
            return SystemMonitorSample(time: now.addingTimeInterval(-600 + t * 10), cpu: cpu, gpu: gpu, memory: 0.64 + 0.02 * sin(t / 9))
        }
    }
}

/// Hidden bar's status items for its page's picture: none reaches this Mac's menu bar.
@MainActor private final class ShotStatusItems: OrganizerStatusItems {
    func setMenuAction(_ action: @escaping (OrganizerMenuAction) -> Void) {}
    func install(_ item: OrganizerItem) {}
    func remove(_ item: OrganizerItem) {}
    func setLength(_ length: CGFloat, for item: OrganizerItem) {}
    func setExpanded(_ expanded: Bool) {}
    func frame(of item: OrganizerItem) -> CGRect? { nil }
    func updateMenu(_ state: OrganizerMenuState) {}
}

@MainActor private final class ShotApplications: OrganizerApplications {
    func watch(_ changed: @escaping () -> Void) {}
    func stopWatching() {}
}

/// Every menu-bar item Frog puts up, drawn by the code its status item draws with, at menu-bar size on strips of
/// menu bar in its light or dark look, each named under it: Frog's own, LLM usage and System monitor in each style
/// and colour, Hidden bar's arrow and dividers, and Stay awake's looks. On the plain backdrop, so the light bar shows.
private struct MenuBarItemsPicture: View {
    let usage: UsageDashboardModel
    @Environment(\.colorScheme) private var scheme

    private enum Glyph {
        case image(NSImage)
        /// Hidden bar's divider, which its status item draws as a view in the button, single or double.
        case divider(double: Bool)
    }
    private struct Item { let label: String; let glyph: Glyph }

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: 14) {
            group("Frog", [Item(label: "Frog", glyph: .image(FrogMenuIcon.image))])
            group("LLM usage", MenuBarMeterStyle.allCases.map { style in
                Item(label: style.title, glyph: .image(usageImage(style: style, palette: .clean, dark: dark)))
            } + [MenuBarMeterPalette.level, .spectrum].map { palette in
                Item(label: "\(MenuBarMeterStyle.segments.title), \(palette.title)",
                     glyph: .image(usageImage(style: .segments, palette: palette, dark: dark)))
            })
            group("System monitor", MenuBarMeterStyle.allCases.map { style in
                Item(label: style.title, glyph: .image(systemImage(style: style, palette: SystemMonitorSettings().menuBarPalette, dark: dark)))
            } + [MenuBarMeterPalette.clean, .level].map { palette in
                Item(label: "\(SystemMonitorSettings().menuBarStyle.title), \(palette.title)",
                     glyph: .image(systemImage(style: SystemMonitorSettings().menuBarStyle, palette: palette, dark: dark)))
            })
            group("Hidden bar", [Item(label: "Shown", glyph: .image(NativeOrganizerStatusItems.arrowImage(expanded: true))),
                                 Item(label: "Hidden", glyph: .image(NativeOrganizerStatusItems.arrowImage(expanded: false))),
                                 Item(label: "Divider", glyph: .divider(double: false)),
                                 Item(label: "Always hidden", glyph: .divider(double: true))])
            // A session with two hours and twenty minutes of four left, as Stay awake's page shows it.
            let deadline = FrogClock.now.addingTimeInterval(140 * 60 + 30)
            group("Stay awake", StayAwakePreferences.menuBarStyles.map { style in
                Item(label: ["icon": "Cup", "ring": "Ring", "time": "Time left"][style] ?? style,
                     glyph: .image(StayAwakeIcon.image(StayAwakeIcon.Face(style: style, deadline: deadline, duration: 4 * 3600))))
            })
        }
    }

    /// LLM usage's item as it reads the sample's plan limits, in `style` and `palette`.
    private func usageImage(style: MenuBarMeterStyle, palette: MenuBarMeterPalette, dark: Bool) -> NSImage {
        var (face, _) = UsageStatusReadout.readout(usage, dark: dark)
        face.style = style
        face.palette = palette
        face.dark = palette != .clean && dark
        return UsageStatusReadout.image(face)
    }

    /// System monitor's item with its default readings (CPU and GPU) on the sample's load.
    private func systemImage(style: MenuBarMeterStyle, palette: MenuBarMeterPalette, dark: Bool) -> NSImage {
        var settings = SystemMonitorSettings()
        settings.menuBarStyle = style
        settings.menuBarPalette = palette
        let reading = SystemMonitorReading(cpu: .value(0.24), gpu: .value(0.11), memory: .value(0.66))
        return MenuBarMeter.image(SystemMonitorStatusItemController.face(reading, settings: settings, dark: dark))
    }

    private func group(_ title: String, _ items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(FrogType.small).foregroundStyle(FrogStyle.muted)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 5) {
                        glyph(item.glyph).frame(height: 24).padding(.horizontal, 10)
                        Text(item.label).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1).fixedSize()
                            .padding(.horizontal, 6)
                    }
                }
            }
            // The menu bar runs behind every item of the group, 24 points tall.
            .background(alignment: .top) {
                Rectangle().fill(scheme == .dark ? Color(white: 0.12).opacity(0.92) : Color.white.opacity(0.78))
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
                    .frame(height: 24)
            }
        }
    }

    @ViewBuilder private func glyph(_ glyph: Glyph) -> some View {
        switch glyph {
        case .image(let image):
            // As the status item's button draws it: a template in the menu bar's ink, a coloured one as it is.
            Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
                .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                .frame(width: image.size.width, height: image.size.height)
        case .divider(let double):
            DividerItemPicture(double: double).frame(width: OrganizerItem.divider.revealedLength(padding: 0), height: 22)
        }
    }
}

/// Hidden bar's divider as its status item draws it: `OrganizerDividerView` in a 22-point button.
private struct DividerItemPicture: NSViewRepresentable {
    let double: Bool

    func makeNSView(context: Context) -> NSButton {
        let width = OrganizerItem.divider.revealedLength(padding: 0)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        button.isBordered = false
        button.title = ""
        _ = OrganizerDividerView(button: button, isDouble: double, width: width)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {}
}

/// A sampler whose first reading never comes, for the loading picture.
private struct StalledSystemSampler: SystemMonitorSampling {
    func sample(reset: Bool, full: Bool) async -> SystemMonitorSnapshot {
        try? await Task.sleep(for: .seconds(3_600))
        return SystemMonitorSnapshot()
    }
}

/// The window's close, minimise and zoom buttons, which an offscreen picture of the window's content leaves out:
/// drawn where macOS puts them in Frog's window (measured from a window made as `FrogApp` makes it), in the
/// colours of a key window.
private struct WindowButtonsPicture: View {
    @MainActor static let frames: [CGRect] = {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: MainView.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "FrogMainShots")
        window.layoutIfNeeded()
        defer { window.close() }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            guard let button = window.standardWindowButton(type) else { return nil }
            let frame = button.convert(button.bounds, to: nil)
            return CGRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
        }
    }()
    private static let colours: [(fill: UInt32, edge: UInt32)] = [(0xFF5F57, 0xE2463F), (0xFEBC2E, 0xE1A116), (0x28C840, 0x14AE2B)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.frames.enumerated()), id: \.offset) { index, frame in
                let colour = Self.colours[min(index, Self.colours.count - 1)]
                Circle().fill(Self.color(colour.fill))
                    .overlay { Circle().strokeBorder(Self.color(colour.edge), lineWidth: 0.5) }
                    .frame(width: frame.width - 1, height: frame.height - 1)
                    .offset(x: frame.minX + 0.5, y: frame.minY + 0.5)
            }
        }
        .allowsHitTesting(false)
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
