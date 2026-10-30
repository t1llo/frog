import XCTest
import AppKit
import SwiftUI
import FrogCore
import FrogTestSupport
import FrogUsage
@testable import FrogApp

/// Pictures of Frog's popups and panels, and of each step of the setup assistant, drawn without a window in light
/// and dark, on a plain backdrop. Runs only with `FROG_SURFACE_SHOTS` set to the folder for the pictures;
/// `FROG_SURFACE_SHOTS_ONLY` picks surfaces and `FROG_SURFACE_SHOTS_LOOK` a look.
@MainActor
final class SurfaceShotsTests: XCTestCase {
    func testEverySurface() async throws {
        guard let folder = ProcessInfo.processInfo.environment["FROG_SURFACE_SHOTS"] else {
            throw XCTSkip("Set FROG_SURFACE_SHOTS to a folder to take these pictures")
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Configuration()
        for feature in FeatureID.allCases { configuration.preferences.setFeature(feature, enabled: true) }
        // `start()` adds Dictate on first launch; these models never start.
        configuration.rules.append(.dictationPreset)
        try ConfigurationStore(directory: root).save(configuration)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        history.configure(enabled: true, automaticallyPoll: false)
        for text in ["git push origin main", "https://frog.beffa.xyz/docs/command-bar/", "Thanks, see you at 3!",
                     "Meeting moved to Thursday", "brew install --cask frog",
                     // A password and a key, made up here: the history never keeps them.
                     "Synth3tic&Pass", "sk-" + "proj-" + SyntheticKey.make(48)] { history.recordCopiedText(text) }
        let usage = UsageDashboardModel(defaults: temporaryDefaults(), fixtureRoot: root.appendingPathComponent("fixtures"))
        let toolkit = Toolkit(makeUsage: { usage }, showsUsageStatusItem: false)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil }, readAccessibility: { true },
                             toolkit: toolkit, clipboardHistoryStore: history,
                             systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()

        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, waitForRelease: {},
                             fileSearch: NoFileSearch(), loadSettings: { [] }, loadApplications: { [] })
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "win"

        let clipboardState = ClipboardHistoryPanelState()
        clipboardState.update(history.entries)
        let switcher = WindowSwitcherDisplay()
        switcher.windows = [
            SwitcherWindow(id: UUID(), pid: 1, appName: "Safari", title: "Frog — Command bar", minimized: false, hidden: false),
            SwitcherWindow(id: UUID(), pid: 2, appName: "Notes", title: "Groceries", minimized: false, hidden: false),
            SwitcherWindow(id: UUID(), pid: 3, appName: "Terminal", title: "~/Projects/frog", minimized: true, hidden: false),
            SwitcherWindow(id: UUID(), pid: 4, appName: "Mail", title: "Inbox", minimized: false, hidden: true)
        ]
        switcher.selected = switcher.windows[1].id
        let picker = LayoutPickerPanel()
        let bubble = [BubbleItem(id: UUID(), title: "Explain", symbol: "text.bubble", answers: true),
                      BubbleItem(id: UUID(), title: "Fix grammar", symbol: "checkmark.circle", answers: false),
                      BubbleItem(id: UUID(), title: "Shorter", symbol: "arrow.down.right.and.arrow.up.left", answers: false)]

        let surfaces: [(String, AnyView)] = [
            ("menu", AnyView(FrogStatusMenu(model: model).environment(\.locale, L10n.locale))),
            ("command-bar", AnyView(CommandBarView(bar: bar))),
            ("clipboard", AnyView(ClipboardHistoryView(state: clipboardState, paste: { _, _ in }, copy: { _ in }, close: {}, resize: {}))),
            ("switcher", AnyView(WindowSwitcherOverlay(model: switcher, choose: { _ in }, hover: { _ in })
                .frame(height: WindowSwitcherLayout.size(windowCount: switcher.windows.count).height))),
            ("layouts", AnyView(LayoutPickerView(panel: picker, measuring: true))),
            ("bubble", AnyView(SelectionBubbleView(visible: bubble, more: bubble, expanded: false, pointer: BubblePointer(),
                                                   select: { _ in }, expand: {})))
        ] + (0..<4).map { step in ("setup-\(step + 1)", AnyView(OnboardingView(step: step).environmentObject(model))) }

        let only = ProcessInfo.processInfo.environment["FROG_SURFACE_SHOTS_ONLY"]?.split(separator: ",").map(String.init)
        // FROG_SURFACE_SHOTS_LOOK=aurora draws them with that look's transparency and glow, standing still.
        let saved = FrogAppearance.shared.settings
        defer { FrogAppearance.shared.apply(saved) }
        if let name = ProcessInfo.processInfo.environment["FROG_SURFACE_SHOTS_LOOK"] {
            let look = try XCTUnwrap(AppearancePreferences.Look(rawValue: name), "Looks: solid, frosted, glass, aurora, prism")
            var value = saved; look.apply(to: &value); value.glowMotion = false
            FrogAppearance.shared.apply(value)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let name = appearance == .aqua ? "light" : "dark"
            for (surface, view) in surfaces where only?.contains(surface) ?? true {
                let host = NSHostingView(rootView: view.padding(24).background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                    .background(Color.gray.opacity(0.35)))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(400))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "\(folder)/popup-\(surface)-\(name).png"))
            }
        }
    }
}

/// The pictures never show files from this Mac.
@MainActor private final class NoFileSearch: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) { receive([]) }
    func stop() {}
}
