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

    func testScrollingWhileTheSelectionIsReadShowsNothing() async throws {
        let fixture = Fixture()
        fixture.reader.holding = true
        fixture.drag()
        try await waitUntil { fixture.reader.heldReads == 1 }
        fixture.watcher.handle(.scroll, now: fixture.now)
        fixture.reader.releaseReads()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.presenter.shows.isEmpty, "The text moved away from where it was read")
    }

    func testAReadThatHangsHoldsUpNoLaterSelection() async throws {
        let fixture = Fixture()
        fixture.reader.holding = true
        fixture.drag()
        try await waitUntil { fixture.reader.heldReads == 1 }
        fixture.reader.holding = false
        fixture.watcher.handle(.applicationChanged, now: fixture.now)
        fixture.frontmost = BubbleApplication(pid: 778, bundleID: "com.apple.TextEdit", bundleURL: nil)
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }
        XCTAssertEqual(fixture.reader.calls.map(\.pid), [Fixture.pid, 778])

        fixture.reader.releaseReads()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.presenter.shows.count, 1, "The late read of the first app shows nothing")
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
            // Nothing selected is read once more, in case the app reported the selection late.
            let reads = result == .empty || result == .unavailable ? 2 : 1
            try await waitUntil { fixture.reader.calls.count == reads }
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertTrue(fixture.presenter.shows.isEmpty, "\(result)")
            XCTAssertEqual(fixture.reader.calls.count, reads, "\(result)")
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

    func testTheSameSelectionComesBackOnlyWhenItIsSelectedAgain() async throws {
        let fixture = Fixture()
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }

        // Dragging the window by its title bar hides the bubble and leaves the selection as it was.
        fixture.drag(from: CGPoint(x: 400, y: 880), to: CGPoint(x: 600, y: 860))
        try await waitUntil { fixture.reader.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(fixture.presenter.isVisible)
        XCTAssertEqual(fixture.presenter.shows.count, 1)

        // A shortcut with Shift, such as ⇧⌘T, ends like a keyboard selection.
        fixture.watcher.handle(.shiftReleased, now: fixture.now)
        try await waitUntil { fixture.reader.calls.count == 3 }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fixture.presenter.shows.count, 1)

        // Double-clicking the same word again brings it back.
        let word = CGPoint(x: 104, y: 508)
        fixture.watcher.handle(.mouseDown(word, clickCount: 2, right: false), now: fixture.now)
        fixture.watcher.handle(.mouseUp(word, clickCount: 2, modifiers: []), now: fixture.now)
        try await waitUntil { fixture.presenter.shows.count == 2 }

        // So does another selection, wherever the gesture ends.
        fixture.watcher.handle(.keyDown(keyCode: 124), now: fixture.now)
        fixture.reader.result = .selection(Self.snapshot("levee bank", element: 1))
        fixture.watcher.handle(.shiftReleased, now: fixture.now)
        try await waitUntil { fixture.presenter.shows.count == 3 }
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

    func testARuleRunByItsShortcutHidesTheBubbleAndDropsAReadAlreadyScheduled() async throws {
        let fixture = Fixture()
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }
        fixture.watcher.dismiss()
        XCTAssertFalse(fixture.presenter.isVisible)

        let scheduled = Fixture()
        scheduled.drag()
        scheduled.watcher.dismiss()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(scheduled.reader.calls.isEmpty)
        XCTAssertTrue(scheduled.presenter.shows.isEmpty, "No bubble beside the rule's answer")

        scheduled.drag()
        try await waitUntil { scheduled.presenter.shows.count == 1 }
    }

    func testAnAppThatHidesItsTextIsAskedOnceAndThenShowsTheBubble() async throws {
        let fixture = Fixture()
        fixture.reader.result = .unavailable
        fixture.reader.exposes = .selection(Self.snapshot())
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }
        XCTAssertEqual(fixture.reader.exposeRequests, [Fixture.pid])
        XCTAssertEqual(fixture.reader.calls.count, 2, "Read again after asking")

        // Asked once per app: a later selection there reads without asking again.
        fixture.watcher.handle(.mouseDown(CGPoint(x: 300, y: 300), clickCount: 1, right: false), now: fixture.now)
        fixture.reader.result = .selection(Self.snapshot("other", element: 2))
        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 2 }
        XCTAssertEqual(fixture.reader.exposeRequests, [Fixture.pid])
    }

    func testWithTheSettingOffNoAppIsAskedButASlowSelectionIsReadAgain() async throws {
        let fixture = Fixture()
        fixture.options.exposeText = false
        fixture.reader.result = .empty
        fixture.reader.exposes = .selection(Self.snapshot())
        fixture.drag()
        try await waitUntil { fixture.reader.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fixture.reader.exposeRequests.isEmpty)
        XCTAssertTrue(fixture.presenter.shows.isEmpty)
    }

    func testCodeEditorsAreNeverAskedToExposeTheirText() async throws {
        let editors: [(Fixture) -> Void] = [
            { $0.frontmost.bundleID = "com.microsoft.VSCode" },
            { $0.frontmost.bundleID = "com.example.fork"; $0.builtOnVSCode = true },
        ]
        for editor in editors {
            let fixture = Fixture()
            editor(fixture)
            fixture.reader.result = .unavailable
            fixture.reader.exposes = .selection(Self.snapshot())
            fixture.drag()
            try await waitUntil { fixture.reader.calls.count == 2 }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(fixture.reader.exposeRequests.isEmpty, "Its screen reader mode would turn on")
            XCTAssertTrue(fixture.presenter.shows.isEmpty)
            XCTAssertEqual(fixture.waits.last, SelectionWatcher.retryWait, "Read again as any other app")
        }
    }

    func testAnAppThatDidNotAnswerInTimeIsAskedAgainWithItsNextSelection() async throws {
        let fixture = Fixture()
        fixture.reader.result = .unavailable
        fixture.reader.exposes = .selection(Self.snapshot())
        fixture.reader.unansweredRequests = 1
        fixture.drag()
        try await waitUntil { fixture.reader.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fixture.presenter.shows.isEmpty)
        XCTAssertEqual(fixture.reader.exposeRequests, [Fixture.pid])

        fixture.drag()
        try await waitUntil { fixture.presenter.shows.count == 1 }
        XCTAssertEqual(fixture.reader.exposeRequests, [Fixture.pid, Fixture.pid])

        // It answered, so a later empty read asks no more.
        fixture.reader.result = .unavailable
        fixture.drag()
        try await waitUntil { fixture.reader.calls.count == 6 }
        XCTAssertEqual(fixture.reader.exposeRequests.count, 2)
    }

    func testAnAppThatRefusesIsGivenAsLongToBuildItsTree() async throws {
        // An Electron app from before mid-2023 takes the request while answering that it refused.
        let fixture = Fixture()
        fixture.reader.result = .unavailable
        fixture.drag()
        try await waitUntil { fixture.reader.calls.count == 2 }
        XCTAssertEqual(fixture.reader.exposeRequests, [Fixture.pid])
        XCTAssertEqual(fixture.waits.count, 2, "The settle, then the pause before reading again")
        XCTAssertEqual(fixture.waits.last, SelectionWatcher.exposeWait)
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
    var builtOnVSCode = false
    var options = SelectionBubbleOptions()
    let items = [BubbleItem(id: UUID(), title: "Explain", symbol: SelectionBubbleItems.answerSymbol, answers: true)]
    var ran: [(BubbleItem, SelectionSnapshot)] = []
    private(set) var watcher: SelectionWatcher!

    init() {
        let system = SelectionWatcher.System(frontmost: { [unowned self] in self.frontmost }, ownPID: Self.ownPID,
                                             secureInput: { [unowned self] in self.secure },
                                             category: { [unowned self] _ in self.category },
                                             builtOnVSCode: { [unowned self] _ in self.builtOnVSCode })
        watcher = SelectionWatcher(
            reader: reader, presenter: presenter,
            hooks: .init(options: { [unowned self] in self.options }, state: { [unowned self] in self.state },
                         items: { [unowned self] _ in (self.items, []) }, run: { [unowned self] in self.ran.append(($0, $1)) }),
            system: system, clock: { [unowned self] in self.now },
            // The settle passes at once; the idle check waits for the test to call it.
            sleep: { [unowned self] delay in
                if delay >= 1 { try await Task.sleep(for: .seconds(3_600)) } else { await self.waited(delay); await Task.yield() }
            })
    }

    /// The waits shorter than the idle check's, in order: settles and the pause before a read again.
    private(set) var waits: [TimeInterval] = []
    private func waited(_ delay: TimeInterval) { waits.append(delay) }

    /// By default the drag ends on the end of the selection the reader reports, as a drag that selects text does.
    func drag(from start: CGPoint = CGPoint(x: 10, y: 10), to end: CGPoint = CGPoint(x: 104, y: 508)) {
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
    private var asked: [pid_t] = []
    /// What the app exposes once it is asked to; nil for an app that does not take the request.
    private var exposed: SelectionReadResult?
    var exposes: SelectionReadResult? {
        get { lock.withLock { exposed } }
        set { lock.withLock { exposed = newValue } }
    }
    /// The app is too busy to answer the next requests, one per entry.
    private var silent = 0
    var unansweredRequests: Int {
        get { lock.withLock { silent } }
        set { lock.withLock { silent = newValue } }
    }
    var exposeRequests: [pid_t] { lock.withLock { asked } }
    func exposeText(pid: pid_t) async -> ExposeTextAnswer {
        lock.withLock {
            asked.append(pid)
            if silent > 0 { silent -= 1; return .noAnswer }
            guard let exposed else { return .refused }
            current = exposed
            return .exposed
        }
    }
    /// While set, a read waits for `releaseReads()`, as a read of an app that does not answer does.
    private var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var holding: Bool {
        get { lock.withLock { holds } }
        set { lock.withLock { holds = newValue } }
    }
    var heldReads: Int { lock.withLock { held.count } }
    func releaseReads() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { held = [] }; return held }
        waiting.forEach { $0.resume() }
    }
    func read(pid: pid_t, maxCharacters: Int, includeContext: Bool) async -> SelectionReadResult {
        let hold = lock.withLock {
            recorded.append(Call(pid: pid, maxCharacters: maxCharacters, includeContext: includeContext))
            return holds
        }
        if hold { await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } } }
        return result
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
