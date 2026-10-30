import AppKit
import FrogCore
import XCTest
@testable import FrogApp

/// How Frog's one clipboard watch hands copies to Phone.
@MainActor
final class PhoneClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var history: ClipboardHistoryStore!
    private var forwarded: [ClipboardCopy] = []

    override func setUp() async throws {
        pasteboard = NSPasteboard.withUniqueName()
        history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        forwarded = []
        history.onCopy = { [unowned self] in self.forwarded.append($0) }
    }

    override func tearDown() async throws {
        history.configure(forwardingCopies: false)
        history.configure(enabled: false)
        pasteboard.releaseGlobally()
    }

    private func copy(_ text: String, marks: [NSPasteboard.PasteboardType] = []) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for mark in marks { item.setString("", forType: mark) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func testForwardingWorksWithoutClipboardHistory() async {
        history.configure(forwardingCopies: true, automaticallyPoll: false)
        copy("Fixture text")
        await history.poll()
        XCTAssertEqual(forwarded, [.text("Fixture text")])
        XCTAssertTrue(history.entries.isEmpty, "History stays off")
    }

    func testMarkedAndSecretCopiesStayOnTheMac() async {
        history.configure(forwardingCopies: true, automaticallyPoll: false)
        for mark in NSPasteboard.PasteboardType.localOnlyMarks {
            copy("Fixture marked", marks: [mark])
            await history.poll()
        }
        copy("sk-" + "proj-" + SyntheticKey.make(60))
        await history.poll()
        XCTAssertTrue(forwarded.isEmpty, "\(forwarded)")
    }

    func testFinderFilesAreNotSentOnTheirOwn() async throws {
        history.configure(forwardingCopies: true, automaticallyPoll: false)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("frog-phone-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        await history.poll()
        XCTAssertTrue(forwarded.isEmpty)
    }

    func testImagesAreSentAsPNG() async throws {
        history.configure(forwardingCopies: true, automaticallyPoll: false)
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in NSColor.black.setFill(); rect.fill(); return true }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        await history.poll()
        guard case let .image(png)? = forwarded.first else { return XCTFail("Expected an image") }
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testTurningForwardingOffStopsIt() async {
        history.configure(forwardingCopies: true, automaticallyPoll: false)
        history.configure(forwardingCopies: false, automaticallyPoll: false)
        copy("Fixture text")
        await history.poll()
        XCTAssertTrue(forwarded.isEmpty)
    }
}
