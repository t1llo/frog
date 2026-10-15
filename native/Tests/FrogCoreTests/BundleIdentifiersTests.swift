import XCTest
@testable import FrogCore

final class BundleIdentifiersTests: XCTestCase {
    private func refused(_ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BundleIdentifiers.validate(ids), file: file, line: line) { error in
            XCTAssertEqual(error.localizedDescription, "Use app bundle identifiers such as com.apple.TextEdit, at most 200.",
                           file: file, line: line)
        }
    }

    func testValidList() throws {
        try BundleIdentifiers.validate([])
        try BundleIdentifiers.validate(Array(SelectionBubbleOptions.defaultExcludedApps))
        try BundleIdentifiers.validate(["com.apple.TextEdit", "org.mozilla.firefox", "com.microsoft.VSCode-Insiders", "a.b"])
        try BundleIdentifiers.validate((0..<200).map { "com.example.app\($0)" })
        try BundleIdentifiers.validate(["a." + String(repeating: "x", count: 253)])
    }

    func testRefusedIdentifiers() {
        refused(["com.apple.Text Edit"])
        refused(["com/apple/TextEdit"])
        refused(["TextEdit"])
        refused([""])
        refused(["com.äpple.TextEdit"])
        refused(["a." + String(repeating: "x", count: 254)])
        refused(["com.apple.TextEdit", "bad"])
    }

    func testAtMostTwoHundred() {
        refused((0..<201).map { "com.example.app\($0)" })
    }
}
