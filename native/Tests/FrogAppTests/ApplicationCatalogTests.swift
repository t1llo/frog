import XCTest
import FrogCore
@testable import FrogApp

final class ApplicationCatalogTests: XCTestCase {
    func testDiscoveryIncludesUtilitiesSkipsNestedHelpersAndPreservesConfiguredShortcuts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Editor.app", "Utilities/Tool.app", "Editor.app/Contents/Helper.app"] {
            let contents = root.appendingPathComponent(name).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundleName": URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        let installed = ApplicationCatalog.scan(roots: [root, root])
        XCTAssertEqual(installed.map(\.name), ["Editor", "Tool"])
        XCTAssertTrue(installed.allSatisfy { !$0.enabled && $0.hotkey == nil && $0.category == .application })
        var configuration = Configuration(); configuration.rules = installed
        XCTAssertNoThrow(try ConfigurationFile.validate(configuration))
        var configured = try XCTUnwrap(installed.first)
        configured.hotkey = Hotkey(keyCode: 0, modifiers: 4096 | 512); configured.enabled = true
        let rows = ApplicationCatalog.rows(installed: installed, configured: [configured])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first, configured)
    }
}
