import AppKit
import SwiftUI
import FrogCore
import XCTest
@testable import FrogApp

@MainActor
final class HistoryScrollPerformanceTests: XCTestCase {
    func testLongTranscriptScrollingStaysWithinFrameBudget() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.preferences.historyEnabled = true
        try ConfigurationStore(directory: directory).save(configuration)
        let length = Int(ProcessInfo.processInfo.environment["FROG_SCROLL_TEXT_LENGTH"] ?? "5000") ?? 5000
        let count = Int(ProcessInfo.processInfo.environment["FROG_SCROLL_ENTRY_COUNT"] ?? "50") ?? 50
        let text = String(repeating: "A lengthy transcript with punctuation and words in a continuous paragraph. ", count: length)
        let entries = (0..<count).map { index in
            HistoryEntry(originalText: text, processedText: "Entry \(index) " + text,
                         ruleName: "Dictate", providerName: "Local", model: "test")
        }
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("history.json"))
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        let host = NSHostingView(rootView: HistoryView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 720, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        var timings: [Double] = []
        for index in 0..<100 {
            let start = ContinuousClock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index * 100)))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            let immediate = start.duration(to: .now)
            try await Task.sleep(for: .milliseconds(1))
            let deferredStart = ContinuousClock.now
            host.layoutSubtreeIfNeeded()
            let elapsed = (immediate + deferredStart.duration(to: .now)).components
            timings.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        timings.sort()
        let p95 = timings[94]
        print("History scroll: p95=\(p95)ms max=\(timings.last!)ms")
        XCTAssertLessThan(p95, 20, "Long History previews must not stall native scrolling")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testPreviewBoundsLayoutWithoutChangingFullTranscript() {
        let original = String(repeating: "👨‍👩‍👧‍👦 café 日本語 ", count: 5000) + "searchable tail"
        let preview = HistoryPreview.text(original)
        XCTAssertEqual(preview, String(original.prefix(512)) + "…")
        XCTAssertEqual(preview.count, 513)
        XCTAssertTrue(original.hasSuffix("searchable tail"))
        XCTAssertEqual(HistoryPreview.text("Short text"), "Short text")
        XCTAssertEqual(HistoryPreview.text(String(repeating: "x", count: 512)).count, 512)
    }
}
