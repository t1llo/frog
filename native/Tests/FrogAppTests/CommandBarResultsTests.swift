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

    func testAFileChosenWithTheArrowKeysStaysChosenWhenALaterBatchLeavesItOut() throws {
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
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, fileSearch: CommandFileStub(),
                             loadSettings: { [] }, loadApplications: { [] })
        defer { bar.stop() }
        let files = (0..<6).map { SearchRecord(id: "file:/fixture/Quarterly fixture \($0).txt", title: "Quarterly fixture \($0).txt", subtitle: "Documents", symbol: "doc") }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "quarterly fixture"
        // Spotlight reports while it gathers, and each report is its first rows as they stand then.
        bar.listFiles(Array(files[0...3]), recent: false)
        XCTAssertEqual(bar.results.map(\.id), files[0...3].map(\.id))
        XCTAssertEqual(bar.selection, 0)

        // Untouched, the first row keeps Return, whatever arrives.
        bar.listFiles([files[4]] + files[0...2], recent: false)
        XCTAssertEqual(bar.results[bar.selection].id, files[4].id)

        // Moved to a file, the choice is that file: a later report without it must not hand Return to another row.
        bar.selection = try XCTUnwrap(bar.results.firstIndex(of: files[2]))
        bar.listFiles([files[4], files[5], files[0], files[1]], recent: false)
        XCTAssertEqual(bar.results[bar.selection].id, files[2].id)
        XCTAssertEqual(bar.results.map(\.id), [4, 5, 0, 2, 1].map { files[$0].id })
        // The report after that may list it again, in its own place.
        bar.listFiles([files[4], files[2], files[0]], recent: false)
        XCTAssertEqual(bar.results.map(\.id), [files[4], files[2], files[0]].map(\.id))
        XCTAssertEqual(bar.results[bar.selection].id, files[2].id)
        // Once the choice moves on, the file is listed only while Spotlight reports it.
        bar.selection = 0
        bar.listFiles([files[4], files[0]], recent: false)
        XCTAssertEqual(bar.results.map(\.id), [files[4], files[0]].map(\.id))
        XCTAssertEqual(bar.selection, 0)

        // The recent files listed before anything is typed follow the same rule.
        bar.query = ""
        bar.listFiles(Array(files[0...4]), recent: true)
        let row = try XCTUnwrap(bar.results.firstIndex(of: files[3]))
        bar.selection = row
        bar.listFiles([files[5], files[4], files[0], files[1], files[2]], recent: true)
        XCTAssertEqual(bar.results[bar.selection].id, files[3].id)
        XCTAssertEqual(bar.selection, row)
    }

    func testAChosenFileFollowsAShorterReportAndOutlastsOneThatFindsNothing() throws {
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
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, fileSearch: CommandFileStub(),
                             loadSettings: { [] }, loadApplications: { [] })
        defer { bar.stop() }
        let files = (0..<4).map { SearchRecord(id: "file:/fixture/Quarterly fixture \($0).txt", title: "Quarterly fixture \($0).txt", subtitle: "Documents", symbol: "doc") }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "quarterly fixture"
        bar.listFiles(files, recent: false)
        bar.selection = try XCTUnwrap(bar.results.firstIndex(of: files[3]))
        // A report with fewer rows than the chosen file's place lists it after all of them.
        bar.listFiles([files[0]], recent: false)
        XCTAssertEqual(bar.results.map(\.id), [files[0], files[3]].map(\.id))
        XCTAssertEqual(bar.results[bar.selection].id, files[3].id)
        // The search that begins with the text can report nothing while the one that contains it still gathers.
        bar.listFiles([], recent: false)
        XCTAssertEqual(bar.results.map(\.id), [files[3].id])
        XCTAssertEqual(bar.results[bar.selection].id, files[3].id)
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

    func testTwoLettersOfAnApplicationIdentifierDoNotListEveryApplication() throws {
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
        let apps = (0..<100).map { index in
            var app = Rule(name: "Fixture Tool \(index)", instructions: "", enabled: false)
            app.action = RuleAction(category: .application)
            app.action?.applicationPath = "/Fixture/Fixture Tool \(index).app"
            app.action?.applicationBundleID = "com.example.FixtureWidget\(index)"
            return app
        }
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, fileSearch: CommandFileStub(),
                             loadSettings: { [] }, loadApplications: { apps }, applicationNames: { _ in [] })
        defer { bar.stop() }
        bar.cacheApplications(apps)
        bar.prepareResults(model, frontPID: nil)
        // `com.`, `example.` and the words every application shared matched them all, ahead of Frog's own rows.
        for query in ["co", "le", "en", "pp"] {
            bar.query = query
            XCTAssertFalse(bar.results.contains { $0.id.hasPrefix("app:") }, query)
        }
        bar.query = "co"
        XCTAssertTrue(bar.results.contains { $0.id == "route:Settings" })
        for query in ["open fixture tool 7", "launch fixture tool 7", "fixturewidget7"] {
            bar.query = query
            XCTAssertEqual(bar.results.first?.id, "app:/Fixture/Fixture Tool 7.app", query)
        }
    }

    func testARowAddedTwiceListsWhatItsActionActsOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        for feature in [FeatureID.commandBar, .scratchpad] { config.preferences.setFeature(feature, enabled: true) }
        try ConfigurationStore(directory: root).save(config)
        // Frog never saves one id twice, but a store edited elsewhere can list it twice.
        let id = UUID()
        let notes = ["Fixture first", "Fixture second"].map { UtilityDocument(id: id, kind: .note, title: $0) }
        let toolkit = root.appendingPathComponent("Toolkit")
        try FileManager.default.createDirectory(at: toolkit, withIntermediateDirectories: true)
        try JSONEncoder().encode(notes).write(to: toolkit.appendingPathComponent("toolkit-documents.json"))
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                             clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        defer { model.shutdown() }
        await model.documents.load()
        XCTAssertEqual(model.documents.items.map(\.title), ["Fixture first", "Fixture second"])
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, fileSearch: CommandFileStub(),
                             loadSettings: { [] }, loadApplications: { [] })
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "fixture"
        // The action of the row is the one added last; so must be the row.
        XCTAssertEqual(bar.results.filter { $0.id == "note:\(id)" }.map(\.title), ["Fixture second"])
    }

    func testACalculationDoesNotTakeTheSlotOfAChoiceThatCanBeSuggestedAgain() async throws {
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
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, waitForRelease: {},
                             fileSearch: CommandFileStub(), loadSettings: { [] }, loadApplications: { [] })
        defer { bar.stop() }
        var chosen = 0
        bar.onToolUse = { if $0 == .commandSelection { chosen += 1 } }
        func choose(_ query: String, id: String? = nil) async throws {
            bar.prepareResults(model, frontPID: nil)
            bar.query = query
            let before = chosen
            bar.choose(try XCTUnwrap(id.map { id in bar.results.firstIndex { $0.id == id } } ?? 0, query))
            for _ in 0..<200 where chosen == before { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(chosen, before + 1, query)
        }
        try await choose("rocket", id: "emoji:🚀")
        XCTAssertEqual(pasteboard.string(forType: .string), "🚀")
        // An answer is never listed again before its sum is typed, so it is no suggestion.
        for index in 0..<40 { try await choose("\(index)+1") }
        XCTAssertEqual(pasteboard.string(forType: .string), "40")
        bar.prepareResults(model, frontPID: nil)
        XCTAssertEqual(bar.results.first?.id, "emoji:🚀")
    }

    func testTheFirstListedApplicationsHaveTheirIconsBeforeTheirRowsAppear() async throws {
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
        let apps = (0..<12).map { index in
            var app = Rule(name: "Fixture App \(index)", instructions: "", enabled: false)
            app.action = RuleAction(category: .application); app.action?.applicationPath = "/Fixture/App \(index).app"
            return app
        }
        let reads = CommandIconReads()
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, loadIcon: { reads.load($0) },
                             fileSearch: CommandFileStub(), loadSettings: { [] }, loadApplications: { apps }, applicationNames: { _ in [] })
        defer { bar.stop() }
        func row(_ index: Int) -> SearchRecord { SearchRecord(id: "app:/Fixture/App \(index).app", title: "Fixture App \(index)") }
        bar.cacheApplications(apps)
        // A row reads the cache as it is first drawn, without reading an icon itself.
        XCTAssertNil(bar.cachedIcon(for: row(0)))
        XCTAssertEqual(reads.count, 0)
        // The applications listed before anything is typed are read ahead, the others when their rows appear.
        await bar.preloadIcons()
        XCTAssertEqual(reads.count, 8)
        for index in 0..<8 { XCTAssertNotNil(bar.cachedIcon(for: row(index)), "App \(index)") }
        XCTAssertNil(bar.cachedIcon(for: row(8)))
        let loaded = await bar.icon(for: row(9))
        XCTAssertNotNil(loaded)
        XCTAssertTrue(bar.cachedIcon(for: row(9)) === loaded)
        XCTAssertEqual(reads.count, 9)
        XCTAssertNil(bar.cachedIcon(for: SearchRecord(id: "features", title: "Manage features")))
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
private final class CommandIconReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func load(_ path: String) -> NSImage {
        lock.lock(); reads += 1; lock.unlock()
        return NSImage(size: NSSize(width: 24, height: 24))
    }
}
@MainActor private final class CommandFileStub: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {}
    func stop() {}
}
