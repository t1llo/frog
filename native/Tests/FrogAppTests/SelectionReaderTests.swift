import ApplicationServices
import XCTest
import FrogCore
@testable import FrogApp

/// The reader against fake elements: no real Accessibility call is made.
final class SelectionReaderTests: XCTestCase {
    private static let pid: pid_t = 4242
    /// Text reads the fake records; none of them may happen before the reader knows it wants the text.
    private static let textReads: Set<String> = [kAXSelectedTextAttribute, kAXValueAttribute, "substring", "AXStringForTextMarkerRange"]

    func testATextFieldSelectionHasItsTextPlaceAndFingerprint() async throws {
        let ax = FakeAX()
        let field = ax.focus(FakeElement(role: kAXTextFieldRole))
        field.value = "The river bank is muddy."
        field.range = CFRange(location: 4, length: 10)
        field.selectedText = "river bank"
        field.editable = true
        field.bounds = ["4,10": CGRect(x: 100, y: 200, width: 80, height: 18), "13,1": CGRect(x: 172, y: 200, width: 8, height: 18)]
        ax.window = FakeElement(role: kAXWindowRole)
        ax.window?.document = URL(string: "file:///tmp/river.txt")

        let snapshot = try selection(await read(ax))
        XCTAssertEqual(snapshot.text, "river bank")
        XCTAssertEqual(snapshot.bounds, CGRect(x: 100, y: 682, width: 80, height: 18))
        XCTAssertEqual(snapshot.endBounds, CGRect(x: 172, y: 682, width: 8, height: 18))
        XCTAssertTrue(snapshot.isEditable)
        XCTAssertEqual(snapshot.source, "file:///tmp/river.txt")
        XCTAssertEqual(snapshot.applicationName, "Notes")
        XCTAssertEqual(snapshot.bundleID, "com.example.notes")
        XCTAssertEqual(snapshot.fingerprint, SelectionFingerprint(pid: Self.pid, element: ObjectIdentifier(field).hashValue,
                                                                  location: 4, length: 10, textHash: "river bank".hashValue))
        XCTAssertNil(snapshot.context, "Context only when asked for")
        XCTAssertFalse(ax.reads.contains("substring"))
    }

    func testAPasswordFieldIsRefusedWithoutReadingItsText() async {
        let ax = FakeAX()
        let field = ax.focus(FakeElement(role: kAXTextFieldRole))
        field.subrole = kAXSecureTextFieldSubrole
        field.range = CFRange(location: 0, length: 8)
        field.selectedText = "hunter22"
        let result = await read(ax)
        XCTAssertEqual(result, .secure)
        XCTAssertTrue(Self.textReads.isDisjoint(with: ax.reads), "\(ax.reads)")
    }

    func testACaretIsEmptyInATextAreaAndUnavailableInAWebArea() async {
        let ax = FakeAX()
        let area = ax.focus(FakeElement(role: kAXTextAreaRole))
        area.range = CFRange(location: 5, length: 0)
        let empty = await read(ax)
        XCTAssertEqual(empty, .empty)

        let web = FakeAX()
        let page = web.focus(FakeElement(role: "AXWebArea"))
        page.range = CFRange(location: 5, length: 0)
        page.markerText = ""
        let unavailable = await read(web)
        XCTAssertEqual(unavailable, .unavailable, "A caret in a web area is not empty to Frog")
    }

    func testAWebAreaWithoutARangeIsReadThroughTextMarkers() async throws {
        let ax = FakeAX()
        let page = ax.focus(FakeElement(role: "AXWebArea"))
        page.markerText = "river bank"
        page.markerBounds = CGRect(x: 50, y: 100, width: 70, height: 20)
        page.url = URL(string: "https://user:pw@example.com/page?token=1#part")

        let snapshot = try selection(await read(ax))
        XCTAssertEqual(snapshot.text, "river bank")
        XCTAssertEqual(snapshot.bounds, CGRect(x: 50, y: 780, width: 70, height: 20))
        XCTAssertEqual(snapshot.endBounds, CGRect(x: 120, y: 780, width: 0, height: 0),
                       "The bottom right corner without the last character's rectangle")
        XCTAssertEqual(snapshot.source, "https://example.com/page")
        XCTAssertEqual(snapshot.fingerprint.location, 0)
        XCTAssertEqual(snapshot.fingerprint.length, 10)
    }

    func testTheWebAreaIsFoundWithinEightParents() async throws {
        func nested(_ depth: Int) -> FakeAX {
            let ax = FakeAX()
            let page = FakeElement(role: "AXWebArea")
            page.markerText = "river bank"
            var parent = page
            for _ in 1..<depth {
                let group = FakeElement(role: kAXGroupRole)
                group.parent = parent
                parent = group
            }
            let text = ax.focus(FakeElement(role: kAXStaticTextRole))
            text.parent = parent
            return ax
        }
        let found = try selection(await read(nested(3)))
        XCTAssertEqual(found.text, "river bank")
        let tooDeep = await read(nested(9))
        XCTAssertEqual(tooDeep, .unavailable)
    }

    func testPageTextInChromiumGetsItsLastCharacterAndParagraph() async throws {
        // A Chromium page reports no text through the range attributes and answers neither range-end attribute.
        let ax = FakeAX()
        let page = ax.focus(FakeElement(role: "AXWebArea"))
        page.range = CFRange(location: 0, length: 0)
        page.selectedText = ""
        let sentence = "We sat on the river bank until the light went."
        page.paragraph = sentence
        page.markerText = "river bank"
        page.markerStart = ("We sat on the " as NSString).length
        page.markerBounds = CGRect(x: 50, y: 100, width: 70, height: 20)
        page.characterBounds = [page.markerStart + 9: CGRect(x: 112, y: 100, width: 8, height: 20)]

        let snapshot = try selection(await read(ax, includeContext: true))
        XCTAssertEqual(snapshot.text, "river bank")
        XCTAssertEqual(snapshot.bounds, CGRect(x: 50, y: 780, width: 70, height: 20))
        XCTAssertEqual(snapshot.endBounds, CGRect(x: 112, y: 780, width: 8, height: 20), "The last character")
        XCTAssertEqual(snapshot.context, sentence)
        XCTAssertFalse(ax.reads.contains("AXStartTextMarkerForTextMarkerRange"), "\(ax.reads)")
        XCTAssertFalse(ax.reads.contains("AXEndTextMarkerForTextMarkerRange"), "\(ax.reads)")
    }

    func testARangeThatCannotBeSplitAsksTheAppForItsEnds() async throws {
        let ax = FakeAX()
        ax.splitsMarkers = false
        let page = ax.focus(FakeElement(role: "AXWebArea"))
        page.answersRangeEnds = true
        page.markerText = "river bank"
        page.markerBounds = CGRect(x: 50, y: 100, width: 70, height: 20)
        page.characterBounds = [9: CGRect(x: 112, y: 100, width: 8, height: 20)]

        let snapshot = try selection(await read(ax))
        XCTAssertEqual(snapshot.endBounds, CGRect(x: 112, y: 780, width: 8, height: 20))
        XCTAssertTrue(ax.reads.contains("AXEndTextMarkerForTextMarkerRange"))
    }

    func testALongPageSelectionIsRefusedBeforeItsTextIsFetched() async {
        let ax = FakeAX()
        let page = ax.focus(FakeElement(role: "AXWebArea"))
        page.markerText = String(repeating: "x", count: 100_001)
        let refused = await read(ax)
        XCTAssertEqual(refused, .tooLong(100_001))
        XCTAssertFalse(ax.reads.contains("AXStringForTextMarkerRange"), "\(ax.reads)")

        // An app that reports no length has its text fetched, and the text decides.
        page.answersMarkerLength = false
        let fetched = await read(ax)
        XCTAssertEqual(fetched, .tooLong(100_001))
        XCTAssertTrue(ax.reads.contains("AXStringForTextMarkerRange"))
    }

    func testContextIsReadOnlyWhenAskedAndALongValueIsNeverReadWhole() async throws {
        let ax = FakeAX()
        let area = ax.focus(FakeElement(role: kAXTextAreaRole))
        let sentence = "We sat on the river bank until the light went."
        let filler = String(repeating: "x", count: 150_000)
        area.value = filler + "\n\n" + sentence + "\n\n" + filler
        let location = (filler as NSString).length + 2 + ("We sat on the " as NSString).length
        area.range = CFRange(location: location, length: 10)
        area.selectedText = "river bank"

        let snapshot = try selection(await read(ax, includeContext: true))
        XCTAssertEqual(snapshot.context, sentence)
        XCTAssertFalse(ax.reads.contains(kAXValueAttribute), "A 300,000-character value is read only around the selection")
        XCTAssertTrue(ax.reads.contains("substring"))
    }

    func testTooLongIsDecidedBeforeTheTextIsFetched() async {
        let ax = FakeAX()
        let area = ax.focus(FakeElement(role: kAXTextAreaRole))
        area.range = CFRange(location: 0, length: 100_001)
        area.selectedText = "long"
        let result = await read(ax)
        XCTAssertEqual(result, .tooLong(100_001))
        XCTAssertTrue(Self.textReads.isDisjoint(with: ax.reads), "\(ax.reads)")
    }

    func testNoFocusedElementIsUnavailable() async {
        let result = await read(FakeAX())
        XCTAssertEqual(result, .unavailable)
    }

    func testAnAppThatDoesNotAnswerHoldsUpNoReadOfAnotherApp() async throws {
        let ax = FakeAX()
        let field = ax.focus(FakeElement(role: kAXTextFieldRole))
        field.range = CFRange(location: 0, length: 10)
        field.selectedText = "river bank"
        let hung: pid_t = 99
        let release = DispatchSemaphore(value: 0)
        ax.stall(hung, until: release)
        let reader = SelectionReader(source: ax.source)
        let stalled = Task { await reader.read(pid: hung, maxCharacters: 100_000, includeContext: false) }
        for _ in 0..<200 where !ax.isStalled { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(ax.isStalled)

        let started = Date()
        let other = try selection(await reader.read(pid: Self.pid, maxCharacters: 100_000, includeContext: false))
        XCTAssertEqual(other.text, "river bank")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "Read while the other app still keeps Frog waiting")
        release.signal()
        _ = await stalled.value
    }

    // MARK: Helpers

    private func read(_ ax: FakeAX, includeContext: Bool = false) async -> SelectionReadResult {
        await SelectionReader(source: ax.source).read(pid: Self.pid, maxCharacters: 100_000, includeContext: includeContext)
    }

    private func selection(_ result: SelectionReadResult, file: StaticString = #filePath, line: UInt = #line) throws -> SelectionSnapshot {
        guard case .selection(let snapshot) = result else {
            XCTFail("Expected a selection, got \(result)", file: file, line: line)
            throw CancellationError()
        }
        return snapshot
    }
}

private final class FakeElement {
    var role: String?
    var subrole: String?
    var range: CFRange?
    var selectedText: String?
    var value: String?
    var parent: FakeElement?
    var editable = false
    /// Accessibility rectangles by "location,length".
    var bounds: [String: CGRect] = [:]
    /// The element answers a selected marker range while this is set, an empty string for a caret.
    var markerText: String?
    /// Where the selected markers start in the page's text.
    var markerStart = 0
    var markerBounds: CGRect?
    /// The rectangle of the one character starting at each index, as a one-character marker range reports it.
    var characterBounds: [Int: CGRect] = [:]
    /// The paragraph the selection starts in, which starts at index 0.
    var paragraph: String?
    /// Safari and Chromium both report a range's length; an app that does not gets its text fetched.
    var answersMarkerLength = true
    /// Only WebKit answers the attributes for a range's first and last marker.
    var answersRangeEnds = false
    var url: URL?
    var document: URL?

    init(role: String?) { self.role = role }
}

/// An opaque marker range that carries its text and its ends.
private final class FakeMarkers: NSObject {
    let text: String
    let start: FakeMarker
    let end: FakeMarker
    init(text: String, start: Int = 0) {
        self.text = text
        self.start = FakeMarker(start)
        end = FakeMarker(start + (text as NSString).length)
    }
    init(from start: FakeMarker, to end: FakeMarker) {
        text = ""
        self.start = start
        self.end = end
    }
}

/// An opaque marker: a position in the page's text.
private final class FakeMarker: NSObject {
    let index: Int
    init(_ index: Int) { self.index = index }
}

private final class FakeAX: @unchecked Sendable {
    let application = FakeElement(role: kAXApplicationRole)
    var focused: FakeElement?
    var window: FakeElement?
    /// Whether Frog can split a marker range into its ends itself, as it can every real one.
    var splitsMarkers = true
    private let lock = NSLock()
    private var recorded: [String] = []
    var reads: [String] { lock.withLock { recorded } }

    @discardableResult
    func focus(_ element: FakeElement) -> FakeElement { focused = element; return element }

    private func record(_ name: String) { lock.withLock { recorded.append(name) } }

    /// A process whose application element is handed out only once the semaphore is signalled, or after three
    /// seconds, as an app that stopped answering keeps a call waiting.
    private var stalls: [pid_t: DispatchSemaphore] = [:]
    private var waiting = false
    var isStalled: Bool { lock.withLock { waiting } }
    func stall(_ pid: pid_t, until release: DispatchSemaphore) { lock.withLock { stalls[pid] = release } }

    private func answer(_ pid: pid_t) {
        guard let release = lock.withLock({ stalls[pid] }) else { return }
        lock.withLock { waiting = true }
        _ = release.wait(timeout: .now() + 3)
        lock.withLock { waiting = false }
    }

    var source: SelectionAXSource {
        @Sendable func fake(_ element: AnyObject) -> FakeElement { element as! FakeElement }
        return SelectionAXSource(
            application: { [self] pid in answer(pid); return application },
            focused: { [self] _ in focused },
            window: { [self] _ in window },
            parent: { fake($0).parent },
            role: { fake($0).role },
            subrole: { fake($0).subrole },
            string: { [self] element, name in
                record(name)
                switch name {
                case kAXSelectedTextAttribute: return fake(element).selectedText
                case kAXValueAttribute: return fake(element).value
                default: return nil
                }
            },
            attribute: { element, name in
                guard name == "AXSelectedTextMarkerRange", let text = fake(element).markerText else { return nil }
                return FakeMarkers(text: text, start: fake(element).markerStart)
            },
            range: { fake($0).range },
            count: { fake($0).value.map { ($0 as NSString).length } },
            substring: { [self] element, range in
                record("substring")
                return fake(element).value.flatMap { AXRead.substring($0, range: range) }
            },
            bounds: { fake($0).bounds["\($1.location),\($1.length)"] },
            parameterized: { [self] element, name, parameter in
                record(name)
                let element = fake(element), markers = parameter as? FakeMarkers
                switch name {
                case "AXStringForTextMarkerRange": return markers?.text as NSString?
                case "AXLengthForTextMarkerRange":
                    guard element.answersMarkerLength, let markers else { return nil }
                    return NSNumber(value: markers.end.index - markers.start.index)
                case "AXBoundsForTextMarkerRange":
                    guard let markers else { return nil }
                    let one = markers.end.index - markers.start.index == 1
                    guard var rect = one ? element.characterBounds[markers.start.index] : element.markerBounds else { return nil }
                    return AXValueCreate(.cgRect, &rect)
                case "AXStartTextMarkerForTextMarkerRange": return element.answersRangeEnds ? markers?.start : nil
                case "AXEndTextMarkerForTextMarkerRange": return element.answersRangeEnds ? markers?.end : nil
                case "AXPreviousTextMarkerForTextMarker":
                    return (parameter as? FakeMarker).map { FakeMarker($0.index - 1) }
                case "AXTextMarkerRangeForUnorderedTextMarkers":
                    let pair = ((parameter as? [AnyObject]) ?? []).compactMap { $0 as? FakeMarker }.sorted { $0.index < $1.index }
                    return pair.count == 2 ? FakeMarkers(from: pair[0], to: pair[1]) : nil
                case "AXParagraphTextMarkerRangeForTextMarker":
                    return parameter is FakeMarker ? element.paragraph.map { FakeMarkers(text: $0) } : nil
                default: return nil
                }
            },
            markerEnds: { [self] range in
                guard splitsMarkers, let markers = range as? FakeMarkers else { return nil }
                return (markers.start, markers.end)
            },
            url: { element, name in name == kAXDocumentAttribute ? fake(element).document : fake(element).url },
            hash: { ObjectIdentifier($0).hashValue },
            isEditable: { fake($0).editable },
            bundleID: { _ in "com.example.notes" },
            applicationName: { _ in "Notes" },
            screens: { [CGRect(x: 0, y: 0, width: 1440, height: 900)] },
            primaryHeight: { 900 })
    }
}
