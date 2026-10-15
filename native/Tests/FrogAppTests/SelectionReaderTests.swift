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
        XCTAssertEqual(snapshot.endBounds, CGRect(x: 120, y: 780, width: 0, height: 0), "The bottom right corner without an end marker")
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
    var markerBounds: CGRect?
    var url: URL?
    var document: URL?

    init(role: String?) { self.role = role }
}

/// An opaque marker range that carries its text.
private final class FakeMarkers: NSObject {
    let text: String
    init(text: String) { self.text = text }
}

private final class FakeAX: @unchecked Sendable {
    let application = FakeElement(role: kAXApplicationRole)
    var focused: FakeElement?
    var window: FakeElement?
    private let lock = NSLock()
    private var recorded: [String] = []
    var reads: [String] { lock.withLock { recorded } }

    @discardableResult
    func focus(_ element: FakeElement) -> FakeElement { focused = element; return element }

    private func record(_ name: String) { lock.withLock { recorded.append(name) } }

    var source: SelectionAXSource {
        @Sendable func fake(_ element: AnyObject) -> FakeElement { element as! FakeElement }
        return SelectionAXSource(
            application: { [self] _ in application },
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
                return FakeMarkers(text: text)
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
                switch name {
                case "AXStringForTextMarkerRange": return (parameter as? FakeMarkers)?.text as NSString?
                case "AXBoundsForTextMarkerRange":
                    guard var rect = fake(element).markerBounds else { return nil }
                    return AXValueCreate(.cgRect, &rect)
                default: return nil
                }
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
