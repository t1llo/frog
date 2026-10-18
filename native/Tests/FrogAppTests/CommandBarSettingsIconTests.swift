import AppKit
import XCTest
import FrogCore
@testable import FrogApp

/// Which icon a System Settings row shows, before and after discovery, decided without presenting the bar's panel.
@MainActor final class CommandBarSettingsIconTests: XCTestCase {
    func testDiscoveryReadsEachPanesIconAndFallsBackWhereItHasNone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func pane(_ name: String, id: String, _ extra: [String: Any] = [:], representations: [[String: Any]] = []) throws {
            let contents = root.appendingPathComponent(name + ".appex/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "XPC!",
                "EXAppExtensionAttributes": ["SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": true, "representations": representations]]]
            info.merge(extra) { _, new in new }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try pane("SecurityPrivacyExtension", id: privacyPane, ["CFBundleIcons": ["ISGraphicIconConfiguration": ["ISTypeIdentifier": "com.apple.graphic-icon.privacy"]]])
        // The first alternative names a type no Mac declares and is passed over.
        try pane("PowerPreferences", id: "com.apple.Battery-Settings.extension", ["CFBundleIconFile": "icon"], representations: [
            ["predicate": "powersource.battery == YES", "sidebar-iconUTTypeIdentifier": "com.example.frog-fixture.undeclared"],
            ["predicate": "powersource.battery == YES", "sidebar-iconUTTypeIdentifier": "public.folder"]])
        try pane("HeadphoneSettingsExtension", id: "com.apple.HeadphoneSettings", ["CFBundleIconFile": "icon"])
        try pane("FixturePane", id: "com.apple.FixturePane", ["CFBundleDisplayName": "Fixture Pane", "CFBundleIconName": "AppIcon"])
        let found = await Task.detached { MacSettingsDiscovery.scan(root: root, legacyRoot: root, languages: ["en"], facts: ["powersource.battery": true]) }.value
        func icon(_ paneID: String) -> SystemSettingIcon? { found.first { $0.paneID == paneID && $0.anchor == nil }?.icon }

        let privacy = found.filter { $0.paneID == privacyPane }
        XCTAssertGreaterThan(privacy.count, 10)
        for setting in privacy {
            guard case .bundle(let path) = setting.icon else { return XCTFail("\(setting.record.title) has no icon") }
            XCTAssertEqual((path as NSString).lastPathComponent, "SecurityPrivacyExtension.appex", setting.record.title)
        }
        XCTAssertEqual(icon("com.apple.Battery-Settings.extension"), .type(identifier: "public.folder"))
        XCTAssertNil(icon("com.apple.HeadphoneSettings"), "Only the placeholder: the System Settings icon")
        XCTAssertNil(icon("com.apple.Wallpaper-Settings.extension"), "A pane this Mac does not have keeps the System Settings icon")
        guard case .bundle(let path) = icon("com.apple.FixturePane") else { return XCTFail("The new pane has no icon") }
        XCTAssertEqual((path as NSString).lastPathComponent, "FixturePane.appex")
        XCTAssertEqual(found.first { $0.paneID == "com.apple.FixturePane" }?.record.title, "Fixture Pane")
    }

    func testAnIconTypeThisMacDoesNotDeclareDrawsTheSystemSettingsIcon() throws {
        let fallback = try XCTUnwrap(pixels(NSWorkspace.shared.icon(forFile: MacSettingsDiscovery.fallbackIconPath)))
        let undeclared = SystemSettingIcon.type(identifier: "com.example.frog-fixture.undeclared").key
        XCTAssertEqual(pixels(MacSettingsDiscovery.image(forIconKey: undeclared)), fallback)
        let folder = SystemSettingIcon.type(identifier: "public.folder").key
        XCTAssertEqual(pixels(MacSettingsDiscovery.image(forIconKey: folder)), pixels(NSWorkspace.shared.icon(for: .folder)))
        XCTAssertNotEqual(pixels(MacSettingsDiscovery.image(forIconKey: folder)), fallback)
    }

    // MARK: - Fixtures

    private let privacyPane = "com.apple.settings.PrivacySecurity.extension"

    private func pixels(_ image: NSImage) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.bitmapData.map { Data(bytes: $0, count: 32 * 128) }
    }
}
