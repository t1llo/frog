import XCTest

/// Code that reads a selection without being asked to must never copy, touch the clipboard or send key events. The
/// only requests it makes of another app are the reader's `AXManualAccessibility` and, for a Chromium browser that
/// refuses that, the screen reader's `AXEnhancedUserInterface`; the person can turn both off.
final class SelectionIsolationTests: XCTestCase {
    /// Paths below `native/FrogApp`.
    private static let files = [
        "Platform/SelectionReader.swift",
        "Platform/SelectionWatcher.swift",
        "Platform/SelectionBubbleController.swift",
        "Views/SelectionBubbleView.swift",
    ]

    private static let forbidden = [
        "NSPasteboard", "ClipboardSelection", "FreshSelectionCopy", "CGEvent(", ".post(",
    ]

    func testSelectionReadingCodeNeverCopiesOrPostsEvents() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FrogApp")
        for file in Self.files {
            let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            for word in Self.forbidden {
                XCTAssertFalse(source.contains(word), "\(file) contains \(word)")
            }
            for request in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                let asks = source.components(separatedBy: request).count - 1
                XCTAssertEqual(asks, file == "Platform/SelectionReader.swift" ? 1 : 0, "\(file) asks apps to expose their text")
            }
        }
    }
}
