import AppKit
import XCTest
import FrogCore
@testable import FrogApp

/// The rows the command bar lists, built without presenting its panel.
@MainActor final class CommandBarResultsTests: XCTestCase {
    func testFocusedFieldIsReadOnlyWhenClipboardRowsOrSnippetsCanPasteIntoIt() throws {
        for (features, expected) in [([FeatureID](), 0), ([.clipboard], 1), ([.snippets], 1)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var config = Configuration(); config.preferences.windowSwitcherEnabled = false
            for feature in [.commandBar] + features { config.preferences.setFeature(feature, enabled: true) }
            try ConfigurationStore(directory: root).save(config)
            let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
            defer { pasteboard.releaseGlobally() }
            let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                                 clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
            defer { model.shutdown() }
            var captures = 0
            let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { captures += 1; return nil },
                                 fileSearch: CommandFileStub(), loadSettings: { [] }, loadApplications: { [] })
            defer { bar.stop() }
            bar.prepareResults(model, frontPID: nil)
            XCTAssertEqual(captures, expected, "Enabled: \(features.map(\.rawValue))")
            XCTAssertTrue(bar.results.contains { $0.id == "features" })
        }
    }
}

@MainActor private final class CommandFileStub: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {}
    func stop() {}
}
