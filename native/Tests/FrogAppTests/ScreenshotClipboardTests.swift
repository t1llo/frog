import AppKit
import XCTest
@testable import FrogApp

@MainActor
final class ScreenshotClipboardTests: XCTestCase {
    private var root: URL!
    private var temporary: URL!
    private var desktop: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("frog-shots-\(UUID().uuidString)").resolvingSymlinksInPath()
        temporary = root.appendingPathComponent("T")
        desktop = root.appendingPathComponent("Desktop")
        for folder in [temporary!, desktop!] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        pasteboard = NSPasteboard(name: NSPasteboard.Name("frog-shots-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func watcher() -> ScreenshotClipboard {
        let desktop = desktop!
        return ScreenshotClipboard(pasteboard: pasteboard, temporaryRoot: temporary, saveFolder: { desktop })
    }

    private func png(at url: URL, marked: Bool) throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.systemGreen.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        guard marked else { return }
        let mark = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        _ = mark.withUnsafeBytes { setxattr(url.path, ScreenshotClipboard.screenCaptureMark, $0.baseAddress, mark.count, 0, 0) }
    }

    func testAMarkedScreenshotInTheSaveFolderIsCopied() throws {
        let shot = desktop.appendingPathComponent("Screenshot 2026-11-07 at 10.00.00.png")
        try png(at: shot, marked: true)
        let watcher = watcher()
        watcher.handle([shot.path])
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertEqual(watcher.lastCopied?.name, "Screenshot 2026-11-07 at 10.00.00")
    }

    func testOtherImagesInTheSaveFolderAreLeftAlone() throws {
        let photo = desktop.appendingPathComponent("holiday.png")
        try png(at: photo, marked: false)
        let watcher = watcher()
        watcher.handle([photo.path])
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertNil(watcher.lastCopied)
    }

    /// While the thumbnail floats, macOS has written the screenshot only to screencaptureui's temporary folder.
    func testTheThumbnailsTemporaryFileIsCopiedAndTheSavedOneSkipped() throws {
        let name = "Screenshot 2026-11-07 at 10.00.01.png"
        let early = temporary.appendingPathComponent("TemporaryItems/NSIRD_screencaptureui_abc123/\(name)")
        try png(at: early, marked: false)
        let watcher = watcher()
        var copies = 0
        watcher.onCopy = { _ in copies += 1 }
        watcher.handle([early.path])
        XCTAssertEqual(copies, 1)
        XCTAssertNotNil(pasteboard.data(forType: .png))

        // The thumbnail goes away and macOS moves the file to the save folder: the same screenshot, not a new one.
        let saved = desktop.appendingPathComponent(name)
        try FileManager.default.moveItem(at: early, to: saved)
        try png(at: saved, marked: true)
        pasteboard.clearContents()
        watcher.handle([saved.path])
        XCTAssertEqual(copies, 1)
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testOtherAppsTemporaryImagesAreLeftAlone() throws {
        let other = temporary.appendingPathComponent("com.example.app/preview.png")
        try png(at: other, marked: false)
        let watcher = watcher()
        watcher.handle([other.path])
        XCTAssertNil(watcher.lastCopied)
    }

    func testAnOldScreenshotTouchedAgainIsNotCopied() throws {
        let shot = desktop.appendingPathComponent("Screenshot 2026-01-01 at 09.00.00.png")
        try png(at: shot, marked: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: shot.path)
        let watcher = watcher()
        watcher.handle([shot.path])
        XCTAssertNil(watcher.lastCopied)
    }

    func testCopyLatestTakesTheNewestScreenshot() throws {
        let older = desktop.appendingPathComponent("Screenshot A.png"), newer = desktop.appendingPathComponent("Screenshot B.png")
        try png(at: older, marked: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-600)], ofItemAtPath: older.path)
        try png(at: newer, marked: true)
        try png(at: desktop.appendingPathComponent("not a screenshot.png"), marked: false)
        let watcher = watcher()
        XCTAssertEqual(watcher.copyLatest()?.name, "Screenshot B")
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }

    /// The real stream: a screenshot written into the watched folder reaches the clipboard on its own.
    func testTheWatcherNoticesANewScreenshot() async throws {
        let watcher = watcher()
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try png(at: desktop.appendingPathComponent("Screenshot 2026-11-07 at 10.00.02.png"), marked: true)
        for _ in 0..<40 where watcher.lastCopied == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(watcher.lastCopied?.name, "Screenshot 2026-11-07 at 10.00.02")
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }
}
