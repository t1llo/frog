import Carbon
import XCTest
@testable import FrogApp

@MainActor
final class CommandKeyTests: XCTestCase {
    // Where the QWERTY key positions of V (9), K (40) and full stop (47) land in each layout.
    private let qwerty: [CGKeyCode: String] = [8: "c", 9: "v", 40: "k", 47: "."]
    private let dvorak: [CGKeyCode: String] = [8: "j", 9: "k", 34: "c", 40: "t", 47: "v"]
    private let russian: [CGKeyCode: String] = [8: "с", 9: "м", 40: "л", 47: "ю"]

    private func code(_ letter: String, fallback: CGKeyCode, plain: [CGKeyCode: String], command: [CGKeyCode: String]) -> CGKeyCode {
        CommandKey.code(for: letter, fallback: fallback) { key, held in (held ? command : plain)[key] }
    }

    func testPasteIsSentFromTheKeyThatTypesVInTheLayout() {
        XCTAssertEqual(code("v", fallback: 9, plain: qwerty, command: qwerty), 9)
        // Dvorak has K where QWERTY has V: key 9 with Command would not paste there.
        XCTAssertEqual(code("v", fallback: 9, plain: dvorak, command: dvorak), 47)
        XCTAssertEqual(code("c", fallback: 8, plain: dvorak, command: dvorak), 34)
    }

    func testLayoutsThatSwitchToQwertyWithCommandKeepTheUsualKey() {
        // "Dvorak – QWERTY ⌘", and layouts of other scripts, type Latin QWERTY letters with Command.
        XCTAssertEqual(code("v", fallback: 9, plain: dvorak, command: qwerty), 9)
        XCTAssertEqual(code("v", fallback: 9, plain: russian, command: qwerty), 9)
    }

    func testLayoutWithoutACommandLayerUsesItsPlainLetters() {
        XCTAssertEqual(code("v", fallback: 9, plain: dvorak, command: [:]), 47)
        XCTAssertEqual(code("v", fallback: 9, plain: [47: "V"], command: [:]), 47)
    }

    func testLayoutWithoutTheLetterFallsBackToTheUsualKey() {
        XCTAssertEqual(code("v", fallback: 9, plain: russian, command: russian), 9)
        XCTAssertEqual(code("v", fallback: 9, plain: [:], command: [:]), 9)
    }

    func testCurrentLayoutIsReadWithoutLeavingTheLetterKeys() {
        // Whatever layout this Mac uses, Paste and Copy come from two different letter keys.
        let paste = CommandKey.code(for: "v", fallback: 9), copy = CommandKey.code(for: "c", fallback: 8)
        XCTAssertTrue((0...50).contains(paste))
        XCTAssertTrue((0...50).contains(copy))
        XCTAssertNotEqual(paste, copy)
    }
}
