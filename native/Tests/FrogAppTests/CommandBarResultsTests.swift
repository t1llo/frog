import AppKit
import XCTest
import FrogCore
@testable import FrogApp

/// The rows the command bar lists and the keys it takes, decided without presenting its panel.
@MainActor final class CommandBarResultsTests: XCTestCase {
    func testAnInputMethodThatIsComposingKeepsEscapeArrowsAndReturn() {
        let keys: [UInt16] = [53, 125, 126, 36, 76]
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        for key in keys { XCTAssertTrue(CommandBar.handlesKey(key, firstResponder: field), "Key \(key)") }
        field.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(field.hasMarkedText())
        for key in keys { XCTAssertFalse(CommandBar.handlesKey(key, firstResponder: field), "Key \(key) while composing") }
        field.unmarkText()
        for key in keys { XCTAssertTrue(CommandBar.handlesKey(key, firstResponder: field), "Key \(key) after composing") }
        XCTAssertTrue(CommandBar.handlesKey(36, firstResponder: nil))
        XCTAssertFalse(CommandBar.handlesKey(0, firstResponder: field))
    }

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

    func testAnApplicationIsFoundUnderItsFinderNameAndItsBundleName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        config.preferences.setFeature(.commandBar, enabled: true)
        try ConfigurationStore(directory: root).save(config)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                             clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        defer { model.shutdown() }
        let path = "/Fixture/Visual Studio Fixture.app"
        var app = Rule(name: "Visual Studio Fixture", instructions: "", enabled: false)
        app.action = RuleAction(category: .application); app.action?.applicationPath = path
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, fileSearch: CommandFileStub(),
                             loadSettings: { [] }, loadApplications: { [app] }, applicationNames: { $0 == path ? ["Code"] : [] })
        defer { bar.stop() }
        bar.cacheApplications([app])
        bar.prepareResults(model, frontPID: nil)
        for query in ["visual studio", "code"] {
            bar.query = query
            XCTAssertEqual(bar.results.first?.id, "app:\(path)", query)
            XCTAssertEqual(bar.results.first?.title, "Visual Studio Fixture")
        }
    }

    func testCopyWhileTheBarIsOpenListsTheEntryAndEarlierRowsStillPaste() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        for feature in [FeatureID.commandBar, .clipboard] { config.preferences.setFeature(feature, enabled: true) }
        try ConfigurationStore(directory: root).save(config)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistoryStore(pasteboard: pasteboard)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil }, clipboardHistoryStore: history)
        defer { model.shutdown() }
        history.configure(enabled: true, automaticallyPoll: false)
        history.recordCopiedText("earlier fixture")
        let target = CommandPasteFixture()
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { target }, waitForRelease: {},
                             fileSearch: CommandFileStub(), loadSettings: { [] }, loadApplications: { [] })
        defer { bar.stop() }
        func clipboardRows() -> [String] { bar.results.filter { $0.id.hasPrefix("clipboard:") }.map(\.title) }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "fixture"
        XCTAssertEqual(clipboardRows(), ["earlier fixture"])

        // A copy in another app reaches the history through its poll.
        pasteboard.clearContents(); pasteboard.setString("polled fixture", forType: .string)
        await history.poll()
        XCTAssertEqual(clipboardRows(), ["polled fixture", "earlier fixture"])

        // A dictation or rule result renews the history's generation. Rows listed before it must still paste.
        history.recordCopiedText("result fixture")
        XCTAssertEqual(clipboardRows(), ["result fixture", "polled fixture", "earlier fixture"])
        XCTAssertEqual(bar.query, "fixture")

        history.delete(id: try XCTUnwrap(history.entries.first { $0.text == "polled fixture" }).id)
        XCTAssertEqual(clipboardRows(), ["result fixture", "earlier fixture"])
        bar.choose(try XCTUnwrap(bar.results.firstIndex { $0.title == "earlier fixture" }))
        for _ in 0..<200 where target.pastes == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(target.pastes, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "earlier fixture")
    }

    func testClearingTheHistoryRemovesItsRowsAndKeepsTheOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        for feature in [FeatureID.commandBar, .clipboard] { config.preferences.setFeature(feature, enabled: true) }
        try ConfigurationStore(directory: root).save(config)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistoryStore(pasteboard: pasteboard)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil }, clipboardHistoryStore: history)
        defer { model.shutdown() }
        history.configure(enabled: true, automaticallyPoll: false)
        history.recordCopiedText("cleared fixture")
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, waitForRelease: {},
                             fileSearch: CommandFileStub(), loadSettings: { [] }, loadApplications: { [] })
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        XCTAssertTrue(bar.results.contains { $0.id.hasPrefix("clipboard:") })
        history.clear()
        XCTAssertFalse(bar.results.contains { $0.id.hasPrefix("clipboard:") })
        XCTAssertTrue(bar.results.contains { $0.id == "features" })
    }
}

@MainActor private final class CommandPasteFixture: ClipboardHistoryPasteTarget {
    var pastes = 0
    func paste() throws { pastes += 1 }
}
@MainActor private final class CommandFileStub: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {}
    func stop() {}
}
