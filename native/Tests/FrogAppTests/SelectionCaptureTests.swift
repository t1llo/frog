import XCTest
@testable import FrogApp

@MainActor
final class SelectionCaptureTests: XCTestCase {
    private final class PlainSelection: CapturedTextSelection {
        let text = "plain"
        func replace(with text: String) async throws {}
    }

    private final class AnchoredSelection: CapturedTextSelection {
        let text = "anchored"
        let anchor: CGRect? = CGRect(x: 10, y: 20, width: 30, height: 16)
        let context: String? = "The anchored word in a sentence."
        let applicationName: String? = "TextEdit"
        let source: String? = "file:///tmp/a.txt"
        func replace(with text: String) async throws {}
    }

    func testCaptureValuesDefaultToNilAndAreRequirements() {
        let plain: any CapturedTextSelection = PlainSelection()
        XCTAssertNil(plain.anchor)
        XCTAssertNil(plain.context)
        XCTAssertNil(plain.applicationName)
        XCTAssertNil(plain.source)

        // Extension-only members would be dispatched statically and return nil here.
        let anchored: any CapturedTextSelection = AnchoredSelection()
        XCTAssertEqual(anchored.anchor, CGRect(x: 10, y: 20, width: 30, height: 16))
        XCTAssertEqual(anchored.context, "The anchored word in a sentence.")
        XCTAssertEqual(anchored.applicationName, "TextEdit")
        XCTAssertEqual(anchored.source, "file:///tmp/a.txt")
    }

    func testEditabilityIsReadOutsideTheMainActorType() throws {
        let platform = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FrogApp/Platform")
        let clipboard = try String(contentsOf: platform.appendingPathComponent("ClipboardSelection.swift"), encoding: .utf8)
        XCTAssertFalse(clipboard.contains("func isEditable"))
        XCTAssertTrue(clipboard.contains("AXRead.isEditable("))
        let pasteTarget = try String(contentsOf: platform.appendingPathComponent("ClipboardHistoryPasteTarget.swift"), encoding: .utf8)
        XCTAssertTrue(pasteTarget.contains("AXRead.isEditable($0)"))
        XCTAssertFalse(pasteTarget.contains("ClipboardSelection.isEditable"))
    }
}
