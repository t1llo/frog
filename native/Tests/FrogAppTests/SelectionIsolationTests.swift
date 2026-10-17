import XCTest

/// Code that reads a selection without being asked to must never copy, touch the clipboard or send key events. The
/// only request it makes of another app is the reader's `AXManualAccessibility`, which the person can turn off.
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
        "AXEnhancedUserInterface",
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
            let asks = source.components(separatedBy: "AXManualAccessibility").count - 1
            XCTAssertEqual(asks, file == "Platform/SelectionReader.swift" ? 1 : 0, "\(file) asks apps to expose their text")
        }
    }
}
