import AppKit
import XCTest
import FrogCore
@testable import FrogApp

/// Where window layouts appear and run while Windows, Shortcuts or both are on, decided without a window.
@MainActor final class WindowsFeatureRoutingTests: XCTestCase {
    func testLayoutRecordsFollowShortcutsOrWindows() throws {
        for (shortcuts, windows) in [(false, true), (false, false), (true, false)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var config = Configuration(); config.preferences.windowSwitcherEnabled = false
            config.preferences.setFeature(.commandBar, enabled: true)
            config.preferences.setFeature(.applicationShortcuts, enabled: shortcuts)
            config.preferences.setFeature(.windows, enabled: windows)
            try ConfigurationStore(directory: root).save(config)
            let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
            defer { pasteboard.releaseGlobally() }
            let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                                 clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
            defer { model.shutdown() }
            let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil },
                                 fileSearch: NoFileSearch(), loadSettings: { [] }, loadApplications: { [] })
            defer { bar.stop() }
            bar.prepareResults(model, frontPID: nil)
            bar.query = WindowAction.leftHalf.title
            XCTAssertEqual(bar.results.contains { $0.id == "layout:\(WindowAction.leftHalf.rawValue)" }, shortcuts || windows,
                           "Shortcuts \(shortcuts), Windows \(windows)")
        }
    }

    func testHotkeyRulesKeepWindowRulesWhileWindowsIsOn() {
        var configuration = Configuration()
        var layout = WindowAction.leftHalf.rule
        layout.hotkey = Hotkey(keyCode: 123, modifiers: 4096 | 2048); layout.enabled = true
        configuration.rules.append(layout)
        configuration.preferences.setFeature(.applicationShortcuts, enabled: false)
        configuration.preferences.setFeature(.windows, enabled: true)
        XCTAssertTrue(AppModel.hotkeyRules(for: configuration).contains { $0.id == layout.id })
        configuration.preferences.setFeature(.windows, enabled: false)
        XCTAssertFalse(AppModel.hotkeyRules(for: configuration).contains { $0.id == layout.id })
    }
}

@MainActor private final class NoFileSearch: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {}
    func stop() {}
}
