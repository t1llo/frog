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

/// Phone is created only while its feature is on.
@MainActor
final class PhoneFeatureTests: XCTestCase {
    func testPhoneRunsOnlyWhileItsFeatureIsOn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-phone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ConfigurationStore(directory: directory).save(Configuration())
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, complete: { text, _, _, _ in text }, readKey: { _ in nil },
                             writeClipboard: { _ in }, clipboardHistoryStore: history)
        model.phoneFactory = {
            PhoneController(store: PhonePairingStore(fileURL: PhonePairingStore.defaultFile(in: directory), secrets: InMemoryPhoneSecretStore()),
                            clipboard: history, downloads: directory, macName: "Test Mac", startsTransports: false)
        }
        model.start()
        defer { model.shutdown() }
        XCTAssertNil(model.phone, "Off by default")
        XCTAssertFalse(history.forwardsCopies)

        try await model.setFeature(.phone, enabled: true)
        XCTAssertNotNil(model.phone)
        XCTAssertTrue(history.forwardsCopies, "Auto-send is on by default")

        model.setPhoneAutoSend(false)
        XCTAssertFalse(history.forwardsCopies)
        XCTAssertEqual(model.configuration.preferences.toolkitSettings.phoneAutoSend, false)

        try await model.setFeature(.phone, enabled: false)
        XCTAssertNil(model.phone)
        XCTAssertFalse(history.forwardsCopies)
    }
}
