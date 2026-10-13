import AppKit
import Combine
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testPickedColourIsSavedAsItsNearestHex() {
        XCTAssertEqual(AppearanceSettingsView.hex(of: NSColor(srgbRed: 0x44 / 255.0, green: 0x55 / 255.0, blue: 0x66 / 255.0, alpha: 1)), "445566")
        // A colour converted from another colour space rarely lands exactly on an 8-bit step.
        XCTAssertEqual(AppearanceSettingsView.hex(of: NSColor(srgbRed: 127.6 / 255, green: 0.4 / 255, blue: 254.6 / 255, alpha: 1)), "8000FF")
    }

    func testDragStepsAreShownAtOnceAndSavedOnceWhenTheyPause() async throws {
        let screen = Screen()
        let draft = screen.draft(delay: .milliseconds(20))
        for step in 1...50 { draft.change(transparency(Double(step) / 50)) }
        XCTAssertEqual(screen.previews.count, 50, "Every step of a drag must be visible")
        XCTAssertEqual(draft.value, transparency(1), "The controls must follow the drag")
        XCTAssertEqual(screen.saves.count, 0, "A step of a drag must not write the settings")
        for _ in 0..<1000 where screen.saves.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(screen.saves.map(\.transparency), [1])
        XCTAssertNil(draft.value)
    }

    func testEndingADragSavesAtOnceAndOnlyOnce() {
        let screen = Screen()
        let draft = screen.draft(delay: .seconds(3600))
        draft.change(transparency(0.2)); draft.change(transparency(0.4))
        draft.commit()
        draft.commit()
        XCTAssertEqual(screen.saves, [transparency(0.4)])
        XCTAssertNil(draft.value)
    }

    func testAChoiceIsSavedAtOnceTogetherWithAWaitingDrag() {
        let screen = Screen()
        let draft = screen.draft(delay: .seconds(3600))
        var dragged = transparency(0.6)
        draft.change(dragged)
        dragged.mode = .dark
        draft.set(dragged)
        XCTAssertEqual(screen.saves, [dragged])
        XCTAssertEqual(screen.previews.last, dragged)
    }

    func testRefusedSaveShowsTheSavedAppearanceAgain() {
        let screen = Screen(); screen.refusesSaves = true
        let draft = screen.draft(delay: .seconds(3600))
        draft.change(transparency(0.8))
        draft.commit()
        XCTAssertEqual(screen.saves, [transparency(0.8)])
        XCTAssertEqual(screen.previews.last, AppearancePreferences(), "What is on screen must be what is saved")
        XCTAssertNil(draft.value)
    }

    func testAppearanceReloadedWhileADragWaitsIsKept() {
        let screen = Screen()
        let draft = screen.draft(delay: .seconds(3600))
        draft.change(transparency(0.8))
        var reloaded = AppearancePreferences(); reloaded.theme = .nord
        screen.stored = reloaded
        draft.commit()
        XCTAssertEqual(screen.saves, [])
        XCTAssertEqual(screen.previews.last, reloaded)
        XCTAssertNil(draft.value)
    }

    func testDraggingASliderWritesTheSettingsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        var writes = 0
        let observation = model.$configuration.dropFirst().sink { _ in writes += 1 }
        defer { observation.cancel() }
        let saved = model.configuration.preferences.appearance
        let draft = AppearanceDraft(model: model, delay: .seconds(3600), preview: { _ in })
        for step in 1...50 { draft.change(transparency(Double(step) / 50)) }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(model.configuration.preferences.appearance, saved)
        draft.commit()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.configuration.preferences.appearance, transparency(1))
        XCTAssertEqual(try ConfigurationStore(directory: directory).load().preferences.appearance, transparency(1))
        XCTAssertNil(model.errorMessage)
    }

    private func transparency(_ amount: Double) -> AppearancePreferences {
        var value = AppearancePreferences(); value.transparency = amount
        return value
    }

    /// Stands in for the app's appearance and its settings file.
    private final class Screen {
        var stored = AppearancePreferences()
        var previews: [AppearancePreferences] = []
        var saves: [AppearancePreferences] = []
        var refusesSaves = false

        @MainActor func draft(delay: Duration) -> AppearanceDraft {
            AppearanceDraft(delay: delay, preview: { self.previews.append($0) }, stored: { self.stored }) { value in
                self.saves.append(value)
                if !self.refusesSaves { self.stored = value }
            }
        }
    }
}
