import AppKit
import XCTest
import FrogCore
@testable import FrogApp

/// Rows that providers add to the command bar, decided without presenting its panel.
@MainActor final class CommandBarProviderTests: XCTestCase {
    private var root: URL!
    private var pasteboard: NSPasteboard!
    private var model: AppModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        config.preferences.setFeature(.commandBar, enabled: true)
        try ConfigurationStore(directory: root).save(config)
        pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                         clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
    }

    override func tearDown() async throws {
        model.shutdown(); model = nil
        pasteboard.releaseGlobally(); pasteboard = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func bar(_ providers: [any CommandBarRowProviding] = []) -> CommandBar {
        CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, waitForRelease: {},
                   fileSearch: ProviderFileStub(), loadSettings: { [] }, loadApplications: { [] }, extraProviders: providers)
    }

    func testACalculationLeadsAndCopiesItsAnswerWithoutBecomingASuggestion() async throws {
        let bar = bar()
        defer { bar.stop() }
        var chosen = 0
        bar.onToolUse = { if $0 == .commandSelection { chosen += 1 } }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "2+3"
        let first = try XCTUnwrap(bar.results.first)
        XCTAssertEqual(first, SearchRecord(id: "calculation:2+3", title: "5", subtitle: "Calculation · Copy result", symbol: "equal.circle"))
        bar.choose(0)
        for _ in 0..<200 where chosen == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(pasteboard.string(forType: .string), "5")
        bar.prepareResults(model, frontPID: nil)
        XCTAssertFalse(bar.results.contains { $0.id.hasPrefix("calculation:") })
        bar.query = "5 mi to km"
        XCTAssertEqual(bar.results.first?.id, "calculation:5 mi to km")
    }

    func testEmojiAreListedAsBefore() {
        let bar = bar()
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "frog"
        let frog = try? XCTUnwrap(bar.results.first { $0.id == "emoji:🐸" })
        XCTAssertEqual(frog?.title, "🐸  Frog")
        XCTAssertEqual(frog?.subtitle, "Emoji · Copy")
        XCTAssertEqual(frog?.symbol, "face.smiling")
        bar.query = "rocket"
        XCTAssertEqual(bar.results.first?.id, "emoji:🚀")
    }

    func testAnInformationalRowIsListedAndChoosingItDoesNothing() {
        let provider = FixtureRows()
        provider.query = { _ in [CommandBarRow(record: SearchRecord(id: "fixture:info", title: "Nothing to do"), placement: .leading)] }
        let bar = bar([provider])
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "fixture"
        XCTAssertEqual(bar.results.first?.id, "fixture:info")
        let listed = bar.results
        bar.choose(0)
        bar.choose(0, copyOnly: true)
        XCTAssertEqual(bar.results, listed)
    }

    func testAConfirmedRowAsksBeforeItRuns() async throws {
        let provider = FixtureRows()
        var runs = 0
        provider.query = { _ in
            [CommandBarRow(record: SearchRecord(id: "fixture:quit", title: "Quit Fixture", subtitle: "Process"), placement: .leading,
                           primary: CommandRowAction(title: "Quit", confirm: "Press Return again to quit Fixture") { runs += 1 })]
        }
        let bar = bar([provider])
        defer { bar.stop() }
        var chosen = 0
        bar.onToolUse = { if $0 == .commandSelection { chosen += 1 } }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "quit"
        XCTAssertEqual(bar.results.first?.subtitle, "Process")
        bar.choose(0)
        XCTAssertEqual(bar.results.first?.subtitle, "Press Return again to quit Fixture")
        XCTAssertEqual(runs, 0)
        // Typing in between disarms it.
        bar.query = "quit "
        XCTAssertEqual(bar.results.first?.subtitle, "Process")
        bar.choose(0)
        XCTAssertEqual(bar.results.first?.subtitle, "Press Return again to quit Fixture")
        bar.choose(0)
        for _ in 0..<200 where chosen == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(runs, 1)
    }

    func testQueryRowsAreListedAroundTheRankedResultsInProviderOrder() {
        let first = FixtureRows(), second = FixtureRows()
        first.query = { _ in
            [CommandBarRow(record: SearchRecord(id: "fixture:a-trailing", title: "A trailing"), placement: .trailing, primary: nil),
             CommandBarRow(record: SearchRecord(id: "fixture:a-leading", title: "A leading"), placement: .leading, primary: nil)]
        }
        second.query = { _ in
            [CommandBarRow(record: SearchRecord(id: "fixture:b-ranked", title: "B ranked"), placement: .ranked, primary: nil),
             CommandBarRow(record: SearchRecord(id: "fixture:b-leading", title: "B leading"), placement: .leading, primary: nil)]
        }
        let bar = bar([first, second])
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "zzfixture"
        bar.listFiles([SearchRecord(id: "file:/fixture/zzfixture.txt", title: "zzfixture.txt", symbol: "doc")], recent: false)
        XCTAssertEqual(bar.results.map(\.id), ["fixture:a-leading", "fixture:b-leading", "file:/fixture/zzfixture.txt", "fixture:a-trailing", "fixture:b-ranked"])
        bar.query = "settings"
        let ids = bar.results.map(\.id)
        XCTAssertEqual(Array(ids.prefix(3)), ["fixture:a-leading", "fixture:b-leading", "route:Settings"])
        XCTAssertEqual(Array(ids.suffix(2)), ["fixture:a-trailing", "fixture:b-ranked"])
    }
}

@MainActor private final class FixtureRows: CommandBarRowProviding {
    var query: (String) -> [CommandBarRow] = { _ in [] }
    func queryRows(for query: String, in context: CommandBarContext) -> [CommandBarRow] { self.query(query) }
}

@MainActor private final class ProviderFileStub: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {}
    func stop() {}
}
