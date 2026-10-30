import XCTest
import FrogCore
@testable import FrogApp

/// The Windows and Window switcher plugins keep config.toml and the preferences that shortcuts still read in step.
@MainActor final class WindowsPluginTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.setFeature(.windows, enabled: true)
        try ConfigurationStore(directory: directory).save(configuration)
        model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
        await model.pluginHost.syncAndWait()
    }

    override func tearDown() async throws {
        model.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private var windows: WindowsPlugin { model.pluginHost.running[WindowsPlugin.info.id] as! WindowsPlugin }
    private var switcher: WindowSwitcherPlugin { model.pluginHost.running[WindowSwitcherPlugin.info.id] as! WindowSwitcherPlugin }
    private var legacy: WindowPreferences { model.configuration.preferences.toolkitSettings.windows ?? WindowPreferences() }
    private func table<Section: ConfigSection>(_ id: String, _ type: Section.Type) throws -> Section {
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.toml"))
        try store.load()
        return try store.section(id, as: type).value
    }

    func testAChangeReachesConfigTomlAndThePreferences() throws {
        windows.update { $0.gap = 12; $0.layoutPicker = true }
        XCTAssertEqual(legacy.gap, 12)
        XCTAssertTrue(legacy.layoutPicker)
        XCTAssertEqual(try table("windows", WindowsSettings.self).gap, 12)
    }

    /// Reload reads the preferences file again; the tables follow, so the next change keeps the reloaded values.
    func testReloadedWindowSettingsAreNotUndoneByTheNextChange() throws {
        var configuration = try ConfigurationStore(directory: directory).load()
        var saved = configuration.preferences.toolkit?.windows ?? WindowPreferences()
        saved.gap = 16
        configuration.preferences.toolkit?.windows = saved
        configuration.preferences.toolkit?.windowSwitcherHotkey = Hotkey(keyCode: 50, modifiers: 2048)
        try ConfigurationStore(directory: directory).save(configuration)
        try model.reloadConfiguration()
        XCTAssertEqual(windows.settings.gap, 16)
        XCTAssertEqual(try table("windows", WindowsSettings.self).gap, 16)
        XCTAssertEqual(switcher.settings.shortcut.hotkey, Hotkey(keyCode: 50, modifiers: 2048))
        windows.update { $0.cycleSizes.toggle() }
        XCTAssertEqual(legacy.gap, 16, "A later change must not put the old gap back")
        XCTAssertEqual(model.configuration.preferences.toolkitSettings.effectiveWindowSwitcherHotkey, Hotkey(keyCode: 50, modifiers: 2048))
    }

    /// When config.toml cannot be saved, the preferences keep their value too.
    func testARefusedSaveChangesNeitherStore() throws {
        let url = directory.appendingPathComponent("config.toml")
        try Data("[windows\ngap = ".utf8).write(to: url)
        windows.update { $0.gap = 24 }
        XCTAssertEqual(windows.settings.gap, 0)
        XCTAssertEqual(legacy.gap, 0)
        XCTAssertThrowsError(try switcher.setShortcut(Hotkey(keyCode: 50, modifiers: 2048)))
        XCTAssertEqual(model.configuration.preferences.toolkitSettings.effectiveWindowSwitcherHotkey, WindowSwitchKeyRouter.defaultHotkey)
    }
}
