import XCTest
import AppKit
import FrogCore
@testable import FrogApp

/// Pictures of the real bubble panel, collapsed, hovered and expanded, in light and dark. It opens the panel on screen
/// and takes that window alone, so it runs only with `FROG_BUBBLE_SHOTS` set to the folder for the pictures.
@MainActor
final class SelectionBubbleShotsTests: XCTestCase {
    func testTheBubbleInEachState() async throws {
        guard let folder = ProcessInfo.processInfo.environment["FROG_BUBBLE_SHOTS"] else {
            throw XCTSkip("Set FROG_BUBBLE_SHOTS to a folder to take pictures of the bubble")
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let shortcut = Hotkey(keyCode: 8, modifiers: 4096 | 512)
        let items = [
            BubbleItem(id: UUID(), title: "Explain", symbol: SelectionBubbleItems.answerSymbol, answers: true, hotkey: Hotkey(keyCode: 14, modifiers: 4096 | 2048)),
            BubbleItem(id: UUID(), title: "Define", symbol: SelectionBubbleItems.answerSymbol, answers: true),
            BubbleItem(id: UUID(), title: "Proofread", symbol: SelectionBubbleItems.writingSymbol, answers: false, hotkey: shortcut),
            BubbleItem(id: UUID(), title: "Polish email", symbol: SelectionBubbleItems.writingSymbol, answers: false),
            BubbleItem(id: UUID(), title: "Translate to German", symbol: SelectionBubbleItems.writingSymbol, answers: false,
                       hotkey: Hotkey(keyCode: 5, modifiers: 4096 | 512)),
        ]
        let few = Array(items.prefix(3))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let name = appearance == .aqua ? "light" : "dark"
            let controller = SelectionBubbleController()
            let anchor = CGRect(x: 400, y: 500, width: 0, height: 16)
            controller.show(visible: few, more: [], anchor: anchor, pointer: anchor.origin)
            try await shoot(controller, "\(folder)/\(name)-bar.png")
            controller.hover.location = CGPoint(x: 100, y: 17)
            try await shoot(controller, "\(folder)/\(name)-bar-hover.png")
            controller.show(visible: Array(items.prefix(3)), more: Array(items.dropFirst(3)), anchor: anchor, pointer: anchor.origin)
            try await shoot(controller, "\(folder)/\(name)-bar-more.png")
            controller.expand()
            controller.hover.location = CGPoint(x: 60, y: 80)
            try await shoot(controller, "\(folder)/\(name)-list.png")
            controller.hide()
        }
        NSApplication.shared.appearance = nil
    }

    private func shoot(_ controller: SelectionBubbleController, _ path: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        let number = try XCTUnwrap(controller.windowNumber)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(number)", path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
    }
}
