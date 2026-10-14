import XCTest
@testable import FrogCore

/// An unknown key's error points to docs/configuration.md, so the reference names everything Frog accepts.
final class ConfigurationReferenceTests: XCTestCase {
    func testTheReferenceNamesEveryKey() throws {
        let reference = try self.reference()
        for key in TextConfiguration.keys {
            // Features are listed by name and colors by role, under `feature.<name>` and `palette.<mode>.<role>`.
            let name = key.hasPrefix("feature.") ? String(key.dropFirst("feature.".count))
                : key.hasPrefix("palette.") ? String(key.split(separator: ".").last ?? "") : key
            XCTAssertTrue(reference.contains("`\(name)`"), "docs/configuration.md does not name \(key)")
        }
    }

    func testTheReferenceNamesEveryShortcutKeyFeatureIDAndTheme() throws {
        let reference = try self.reference()
        // Letters, digits and f1–f12 are named as groups.
        for name in ConfigShortcut.keys.keys where name.count > 1 && !(name.first == "f" && Int(name.dropFirst()) != nil) {
            XCTAssertTrue(reference.contains("`\(name)`"), "docs/configuration.md does not name the key \(name)")
        }
        for feature in FeatureID.allCases where feature.rawValue.contains(where: \.isUppercase) {
            XCTAssertTrue(reference.contains("`\(feature.rawValue)`"), "docs/configuration.md does not give the ID \(feature.rawValue)")
        }
        for theme in AppearancePreferences.Theme.allCases {
            XCTAssertTrue(reference.contains("`\(theme.rawValue)`"), "docs/configuration.md does not list the theme \(theme.rawValue)")
        }
    }

    private func reference() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent("docs/configuration.md"), encoding: .utf8)
    }
}
