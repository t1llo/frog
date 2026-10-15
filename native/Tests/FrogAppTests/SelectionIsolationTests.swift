import XCTest

/// Code that reads a selection without being asked to must never copy, touch the clipboard, send key events or make
/// another app build its accessibility tree.
final class SelectionIsolationTests: XCTestCase {
    /// Paths below `native/FrogApp`.
    private static let files = [
        "Platform/SelectionReader.swift",
    ]

    private static let forbidden = [
        "NSPasteboard", "ClipboardSelection", "FreshSelectionCopy", "CGEvent(", ".post(",
        "AXManualAccessibility", "AXEnhancedUserInterface",
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
        }
    }
}
