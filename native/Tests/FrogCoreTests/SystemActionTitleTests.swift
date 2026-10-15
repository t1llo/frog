import XCTest
@testable import FrogCore

/// System actions are named in sentence case, like the settings rows beside them.
final class SystemActionTitleTests: XCTestCase {
    /// Names that keep their capital letter wherever they stand in a title.
    private let properNouns: Set<String> = [
        "Mac", "Finder", "Wi-Fi", "Bluetooth", "System", "Privacy", "Security",
        "Desktop", "Documents", "Downloads", "Applications", "Utilities", "Library"
    ]

    func testTitlesUseSentenceCase() {
        for action in SystemAction.allCases {
            let words = action.title.split(separator: " ").map(String.init)
            XCTAssertTrue(words.first?.first?.isUppercase == true, "\(action): \(action.title)")
            for (index, word) in words.enumerated().dropFirst() where word.first?.isUppercase == true {
                let allowed = properNouns.contains(word) || (word == "Settings" && words[index - 1] == "System")
                XCTAssertTrue(allowed, "\(action): \"\(word)\" in \(action.title)")
            }
        }
    }

    func testTitlesAreUnique() {
        let titles = SystemAction.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "\(titles)")
    }

    func testARuleIsNamedAfterItsAction() {
        XCTAssertEqual(SystemAction.lockScreen.rule.name, "Lock screen")
    }
}
