import XCTest
import FrogCore
@testable import FrogApp

/// Drives the watcher through `handle` with a fake reader, presenter and clock. `start()` is never called, so no
/// global monitor is installed.
@MainActor
final class SelectionWatcherTests: XCTestCase {
    nonisolated static let end = CGRect(x: 100, y: 500, width: 8, height: 16)

    func testADragReadsOnceWithoutContextAfterTheSettleAndShowsTheItems() async throws {
        let fixture = Fixture()
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }
        XCTAssertEqual(fixture.reader.calls.count, 1)
        XCTAssertEqual(fixture.reader.calls.first?.pid, Fixture.pid)
        XCTAssertEqual(fixture.reader.calls.first?.includeContext, false)
        XCTAssertEqual(fixture.reader.calls.first?.maxCharacters, 4_000)
        let shown = try XCTUnwrap(fixture.presenter.shows.first)
        XCTAssertEqual(shown.visible, fixture.items)
        XCTAssertEqual(shown.anchor, CGRect(x: 108, y: 500, width: 0, height: 16), "At the end of the selection")
        XCTAssertTrue(fixture.presenter.isVisible)
    }

    func testALaterInputBeforeTheSettleCancelsTheFirstRead() async throws {
        let fixture = Fixture()
        fixture.drag()
        fixture.drag(from: CGPoint(x: 10, y: 80))
        try await waitUntil { fixture.presenter.shows.count == 1 }
        XCTAssertEqual(fixture.reader.calls.count, 1)

        let clicked = Fixture()
        clicked.drag()
        clicked.watcher.handle(.mouseDown(CGPoint(x: 300, y: 300), clickCount: 1, right: false), now: clicked.now)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(clicked.reader.calls.isEmpty)
        XCTAssertTrue(clicked.presenter.shows.isEmpty)
    }

    func testBusySecureInputExcludedAppsAndGamesAreNeverRead() async throws {
        let blocks: [(Fixture) -> Void] = [
            { $0.state.busy = true },
            { $0.secure = true },
            { $0.frontmost.bundleID = "com.1password.1password" },
            { $0.category = "public.app-category.action-games" },
            { $0.frontmost.pid = Fixture.ownPID },
            { $0.state.accessibilityTrusted = false },
        ]
        for block in blocks {
            let fixture = Fixture()
            block(fixture)
            fixture.drag()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(fixture.reader.calls.isEmpty)
            XCTAssertTrue(fixture.presenter.shows.isEmpty)
        }
    }

    func testEmptySecureAndWhitespaceSelectionsShowNothing() async throws {
        for result in [SelectionReadResult.empty, .secure, .unavailable, .selection(Self.snapshot(" \n\t "))] {
            let fixture = Fixture()
            fixture.reader.result = result
            fixture.drag()
            try await waitUntil { fixture.reader.calls.count == 1 }
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertTrue(fixture.presenter.shows.isEmpty, "\(result)")
        }
    }

    func testEscapeDismissesAndTheSameSelectionDoesNotComeBack() async throws {
        let fixture = Fixture()
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }
        fixture.watcher.handle(.keyDown(keyCode: 53), now: fixture.now)
        XCTAssertFalse(fixture.presenter.isVisible)

        fixture.drag()
        try await waitUntil { fixture.reader.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fixture.presenter.shows.count, 1, "The selection dismissed with Escape stays dismissed")

        fixture.reader.result = .selection(Self.snapshot("levee bank", element: 2))
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 2 }
    }

    func testAnyOtherKeyDismissesWithoutRememberingTheSelection() async throws {
        let fixture = Fixture()
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }
        fixture.watcher.handle(.keyDown(keyCode: 0), now: fixture.now)
        XCTAssertFalse(fixture.presenter.isVisible)
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 2 }
    }

    func testWithoutAPositionAMouseGestureUsesTheMouseUpPointAndAKeyboardOneShowsNothing() async throws {
        let fixture = Fixture()
        fixture.reader.result = .selection(Self.snapshot(end: nil))
        fixture.watcher.handle(.shiftReleased, now: fixture.now)
        try await waitUntil { fixture.reader.calls.count == 1 }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(fixture.presenter.shows.isEmpty)

        fixture.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 40))
        try await waitUntil { fixture.presenter.shows.count == 1 }
        XCTAssertNil(fixture.presenter.shows.first?.anchor)
        XCTAssertEqual(fixture.presenter.shows.first?.pointer, CGPoint(x: 90, y: 40))
    }

    func testTheBubbleGoesAwayAfterSixIdleSecondsAndHoveringKeepsIt() async throws {
        let fixture = Fixture()
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }
        fixture.presenter.onHover?(true)
        fixture.now.addTimeInterval(10)
        fixture.watcher.checkIdle()
        XCTAssertTrue(fixture.presenter.isVisible, "The pointer is over it")
        fixture.presenter.onHover?(false)
        fixture.now.addTimeInterval(5)
        fixture.watcher.checkIdle()
        XCTAssertTrue(fixture.presenter.isVisible)
        fixture.now.addTimeInterval(1)
        fixture.watcher.checkIdle()
        XCTAssertFalse(fixture.presenter.isVisible)
    }

    func testChoosingAnItemHidesTheBubbleAndRunsItForTheSelection() async throws {
        let fixture = Fixture()
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }
        fixture.presenter.onSelect?(fixture.items[0])
        XCTAssertFalse(fixture.presenter.isVisible)
        XCTAssertEqual(fixture.ran.map(\.0), [fixture.items[0]])
        XCTAssertEqual(fixture.ran.first?.1.text, "levee")
    }

    static func snapshot(_ text: String = "levee", element: Int = 1, end: CGRect? = SelectionWatcherTests.end) -> SelectionSnapshot {
        SelectionSnapshot(text: text, bounds: end, endBounds: end, context: nil, source: nil, isEditable: false,
                          pid: Fixture.pid, bundleID: "com.apple.Safari", applicationName: "Safari",
                          fingerprint: SelectionFingerprint(pid: Fixture.pid, element: element, location: 0,
                                                            length: text.utf16.count, textHash: text.hashValue))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition not met", file: file, line: line)
    }
}

@MainActor
private final class Fixture {
    static let pid: pid_t = 777
    static let ownPID: pid_t = 1
    var now = Date(timeIntervalSince1970: 1_000)
    let reader = Reader(.selection(SelectionWatcherTests.snapshot()))
    let presenter = Presenter()
    var state = BubbleState(explainEnabled: true, bubbleEnabled: true, writingEnabled: true, accessibilityTrusted: true, busy: false)
    var frontmost = BubbleApplication(pid: Fixture.pid, bundleID: "com.apple.Safari", bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"))
    var secure = false
    var category: String?
    let items = [BubbleItem(id: UUID(), title: "Explain", symbol: SelectionBubbleItems.answerSymbol, answers: true)]
    var ran: [(BubbleItem, SelectionSnapshot)] = []
    private(set) var watcher: SelectionWatcher!

    init() {
        let system = SelectionWatcher.System(frontmost: { [unowned self] in self.frontmost }, ownPID: Self.ownPID,
                                             secureInput: { [unowned self] in self.secure },
                                             category: { [unowned self] _ in self.category })
        watcher = SelectionWatcher(
            reader: reader, presenter: presenter,
            hooks: .init(options: { SelectionBubbleOptions() }, state: { [unowned self] in self.state },
                         items: { [unowned self] _ in (self.items, []) }, run: { [unowned self] in self.ran.append(($0, $1)) }),
            system: system, clock: { [unowned self] in self.now },
            // The settle passes at once; the idle check waits for the test to call it.
            sleep: { delay in if delay >= 1 { try await Task.sleep(for: .seconds(3_600)) } else { await Task.yield() } })
    }

    func drag(from start: CGPoint = CGPoint(x: 10, y: 10), to end: CGPoint = CGPoint(x: 80, y: 10)) {
        watcher.handle(.mouseDown(start, clickCount: 1, right: false), now: now)
        watcher.handle(.mouseUp(end, clickCount: 1, modifiers: []), now: now)
    }
}

private final class Reader: SelectionReading, @unchecked Sendable {
    struct Call { var pid: pid_t; var maxCharacters: Int; var includeContext: Bool }
    private let lock = NSLock()
    private var current: SelectionReadResult
    private var recorded: [Call] = []
    init(_ result: SelectionReadResult) { current = result }
    var result: SelectionReadResult {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    var calls: [Call] { lock.withLock { recorded } }
    func read(pid: pid_t, maxCharacters: Int, includeContext: Bool) async -> SelectionReadResult {
        lock.withLock {
            recorded.append(Call(pid: pid, maxCharacters: maxCharacters, includeContext: includeContext))
            return current
        }
    }
}

@MainActor
private final class Presenter: SelectionBubblePresenting {
    struct Show { var visible: [BubbleItem]; var more: [BubbleItem]; var anchor: CGRect?; var pointer: CGPoint }
    var isVisible = false
    var onHover: ((Bool) -> Void)?
    var onSelect: ((BubbleItem) -> Void)?
    var shows: [Show] = []
    func show(visible: [BubbleItem], more: [BubbleItem], anchor: CGRect?, pointer: CGPoint) {
        isVisible = true
        shows.append(Show(visible: visible, more: more, anchor: anchor, pointer: pointer))
    }
    func hide() { isVisible = false }
}
