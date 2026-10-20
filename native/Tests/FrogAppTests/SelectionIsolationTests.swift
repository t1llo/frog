import XCTest

/// Code that reads a selection without being asked to must never copy, touch the clipboard or send key events, and
/// never asks another app to expose more: `AXManualAccessibility` and the screen reader's `AXEnhancedUserInterface`
/// make Chrome and Electron apps build their whole accessibility tree and stay slower for as long as they run.
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
                XCTAssertEqual(asks, 0, "\(file) asks apps to expose their text")
            }
        }
    }
}
