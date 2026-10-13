import AppKit
import XCTest
import FrogCore
@testable import FrogApp

/// The rows the command bar lists, the keys it takes and where it opens, decided without presenting its panel.
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

    func testTheBarOpensOnTheDisplayInUseAndKeepsAPlaceItWasDraggedTo() {
        let laptop = NSRect(x: 0, y: 0, width: 1440, height: 875), external = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        let size = NSSize(width: 600, height: 390)
        func middle(of display: NSRect) -> NSPoint { NSPoint(x: display.midX - 300, y: display.midY - 195) }
        let resting = NSRect(origin: middle(of: laptop), size: size)
        // Left where it opened, the bar follows the pointer to the other display and back.
        XCTAssertEqual(CommandBar.openingOrigin(of: resting, dragged: false, displays: [laptop, external], inUse: external), middle(of: external))
        XCTAssertEqual(CommandBar.openingOrigin(of: resting, dragged: false, displays: [laptop, external], inUse: laptop), resting.origin)
        // A place it was dragged to is kept, whichever display the pointer is on.
        let placed = NSRect(origin: NSPoint(x: 40, y: 60), size: size)
        XCTAssertEqual(CommandBar.openingOrigin(of: placed, dragged: true, displays: [laptop, external], inUse: external), placed.origin)
        // Until the display it was dragged to is disconnected.
        let lost = NSRect(origin: NSPoint(x: 2000, y: 300), size: size)
        XCTAssertEqual(CommandBar.openingOrigin(of: lost, dragged: true, displays: [laptop], inUse: laptop), middle(of: laptop))
        XCTAssertEqual(CommandBar.openingOrigin(of: lost, dragged: true, displays: [], inUse: nil), lost.origin)
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

    func testSnippetsNotesShelfItemsAndScriptsAreListedWithoutWaitingForTheApplicationList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        for feature in [FeatureID.commandBar, .snippets, .scratchpad, .shelf, .scripts] { config.preferences.setFeature(feature, enabled: true) }
        try ConfigurationStore(directory: root).save(config)
        let saved = [UtilityDocument.Kind.snippet, .note, .shelf, .script].map { UtilityDocument(kind: $0, title: "Fixture \($0.rawValue)") }
        try await UtilityDocumentStore(directory: root.appendingPathComponent("Toolkit")).save(saved, revision: 0)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                             clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        defer { model.shutdown() }
        var applicationLoads = 0
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, fileSearch: CommandFileStub(),
                             loadSettings: { [] }, loadApplications: { applicationLoads += 1; return [] })
        defer { bar.stop() }
        let expected = zip(["snippet", "note", "shelf", "script"], saved).map { "\($0):\($1.id)" }
        func documentRows() -> [String] { bar.results.map(\.id).filter { id in expected.contains(id) } }

        // The first open after launch reads the store. Its rows arrive on their own, not behind the application scan.
        XCTAssertFalse(model.documents.loaded)
        bar.prepareResults(model, frontPID: nil)
        bar.query = "fixture"
        for _ in 0..<200 where documentRows().count < expected.count { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(documentRows(), expected)
        XCTAssertEqual(bar.query, "fixture")

        // From then on they are listed with the first rows, so Return finds a snippet as soon as its name is typed.
        bar.hide()
        bar.prepareResults(model, frontPID: nil)
        bar.query = "fixture snippet"
        XCTAssertEqual(bar.results.first?.id, expected[0])
        XCTAssertEqual(applicationLoads, 0)

        // A store that is still being read when the bar closes adds nothing to the closed bar.
        let late = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                            clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        defer { late.shutdown() }
        bar.hide()
        bar.prepareResults(late, frontPID: nil)
        bar.hide()
        await late.documents.load()
        await Task.yield()
        XCTAssertTrue(bar.results.isEmpty)
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
