import AppKit
import XCTest
import FrogCore
@testable import FrogApp

/// The command bar's window command rows, built without presenting the bar.
@MainActor final class WindowCommandRowsTests: XCTestCase {
    private var root: URL!
    private var pasteboard: NSPasteboard!
    private var model: AppModel?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    }

    override func tearDown() async throws {
        model?.shutdown(); model = nil
        pasteboard.releaseGlobally(); pasteboard = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func rows(windows: Bool, picker: Bool, frontPID: pid_t? = nil) throws -> [CommandBarRow] {
        model?.shutdown()
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        config.preferences.ensureToolkit()
        config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.setFeature(.windows, enabled: windows)
        var settings = WindowPreferences(); settings.layoutPicker = picker
        config.preferences.toolkit?.windows = settings
        let directory = root.appendingPathComponent(UUID().uuidString)
        try ConfigurationStore(directory: directory).save(config)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil },
                             clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        self.model = model
        let context = CommandBarContext(model: model, frontPID: frontPID, pasteboard: pasteboard, pasteTarget: nil,
                                        waitForRelease: {}, copy: { _ in })
        return WindowCommandRows().rows(in: context)
    }

    func testNoRowsWhileWindowsOrThePickerIsOff() throws {
        XCTAssertTrue(try rows(windows: false, picker: true).isEmpty)
        XCTAssertTrue(try rows(windows: true, picker: false).isEmpty)
        XCTAssertTrue(try rows(windows: false, picker: false).isEmpty)
    }

    func testThePickerRowWhileBothAreOn() throws {
        let rows = try rows(windows: true, picker: true)
        XCTAssertEqual(rows.map(\.record.id), ["layout:command.layoutPicker"])
        let record = try XCTUnwrap(rows.first?.record)
        XCTAssertEqual(record.title, WindowCommand.layoutPicker.title)
        XCTAssertEqual(record.title, "Arrange window…")
        XCTAssertEqual(record.subtitle, "Choose a layout")
        XCTAssertEqual(record.symbol, "rectangle.split.2x1")
        XCTAssertTrue(record.keywords.contains("arrange"))
        XCTAssertEqual(rows.first?.primary?.title, "Open")
    }

    func testOpeningRefusesWhenTheFrontAppChanged() async throws {
        // No app has a negative pid, so the front app always differs.
        let row = try XCTUnwrap(try rows(windows: true, picker: true, frontPID: -1).first)
        do {
            try await row.primary?.run()
            XCTFail("The row must refuse")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The target application changed. Open the command bar again.")
        }
    }
}
