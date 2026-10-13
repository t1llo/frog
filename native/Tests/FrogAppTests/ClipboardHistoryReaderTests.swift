import AppKit
import XCTest
@testable import FrogApp

/// The reader alone against a pasteboard of its own: no store, no panel, no shortcut.
final class ClipboardHistoryReaderTests: XCTestCase {
    func testCopiedFileIsNotRecordedAsItsName() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let reader = ClipboardHistoryReader(name: pasteboard.name, gate: ClipboardHistoryCaptureGate())

        let file = NSPasteboardItem()
        file.setString("file:///tmp/Report.pdf", forType: .fileURL)
        file.setString("Report.pdf", forType: .string)
        pasteboard.clearContents(); pasteboard.writeObjects([file])
        var seen = await reader.read(after: pasteboard.changeCount - 1)
        XCTAssertNil(seen.entry, "The name of a copied file is not copied text")
        XCTAssertFalse(seen.retry)
        XCTAssertEqual(seen.changeCount, pasteboard.changeCount)

        // An application that still declares file names the old way.
        let names = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.declareTypes([names, .string], owner: nil)
        pasteboard.setPropertyList(["/tmp/Report.pdf"], forType: names)
        pasteboard.setString("Report.pdf", forType: .string)
        seen = await reader.read(after: pasteboard.changeCount - 1)
        XCTAssertNil(seen.entry)
        XCTAssertFalse(seen.retry)
    }

    func testTextBesideAnImageRenderingIsStillRecorded() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let reader = ClipboardHistoryReader(name: pasteboard.name, gate: ClipboardHistoryCaptureGate())
        let rtf = Data("{\\rtf1\\ansi\\b Bold text}".utf8)
        let item = NSPasteboardItem()
        item.setString("Bold text", forType: .string); item.setData(rtf, forType: .rtf)
        item.setData(Data([1, 2, 3]), forType: .png); item.setData(Data([4, 5, 6]), forType: .pdf)
        pasteboard.clearContents(); pasteboard.writeObjects([item])
        let seen = await reader.read(after: pasteboard.changeCount - 1)
        XCTAssertEqual(seen.entry?.text, "Bold text")
        XCTAssertEqual(seen.entry?.formatting, [NSPasteboard.PasteboardType.rtf.rawValue: rtf])
    }
}
