import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class HistoryLimitsTests: XCTestCase {
    func testLoweringALimitDeletesNothingUntilItIsConfirmed() throws {
        let fixture = try Fixture(entries: 5)
        defer { fixture.close() }
        let draft = HistoryLimitsDraft(model: fixture.model, delay: .seconds(3600))
        draft.change(.init(entries: 3, days: 30))
        XCTAssertEqual(draft.value, .init(entries: 3, days: 30), "The stepper must show the step")
        XCTAssertNil(draft.question, "A step is not asked about before the stepping pauses")
        draft.ask()
        XCTAssertEqual(draft.question, .init(limits: .init(entries: 3, days: 30), dropped: 2))
        XCTAssertEqual(fixture.model.configuration.preferences.historyLimit, 200)
        XCTAssertEqual(fixture.model.history.count, 5)
        XCTAssertEqual(try Data(contentsOf: fixture.model.historyFileURL), fixture.saved, "Nothing may be deleted before the answer")

        draft.cancel()
        XCTAssertNil(draft.value, "The stepper must show the saved limit again")
        XCTAssertNil(draft.question)
        XCTAssertEqual(fixture.model.configuration.preferences.historyLimit, 200)
        XCTAssertEqual(try Data(contentsOf: fixture.model.historyFileURL), fixture.saved, "Cancelling must leave the history as it was")

        draft.change(.init(entries: 3, days: 30)); draft.ask()
        draft.confirm(try XCTUnwrap(draft.question))
        XCTAssertNil(draft.value); XCTAssertNil(draft.question)
        XCTAssertEqual(fixture.model.configuration.preferences.historyLimit, 3)
        XCTAssertEqual(fixture.model.history.map(\.id), Array(fixture.entries.prefix(3)).map(\.id), "The newest entries are the ones that stay")
        XCTAssertEqual(try HistoryStore(directory: fixture.directory).load(preferences: fixture.model.configuration.preferences).count, 3)
        XCTAssertNil(fixture.model.errorMessage)
    }

    func testShorterRetentionIsAskedAboutWithTheNumberOfExpiredEntries() throws {
        let fixture = try Fixture(entries: 5)
        defer { fixture.close() }
        let draft = HistoryLimitsDraft(model: fixture.model, delay: .seconds(3600))
        // The fixture saves one entry a day.
        draft.change(.init(entries: 200, days: 2)); draft.ask()
        XCTAssertEqual(draft.question?.dropped, 3)
        XCTAssertEqual(try Data(contentsOf: fixture.model.historyFileURL), fixture.saved)
    }

    func testAChangeThatDeletesNothingIsSavedAtOnce() throws {
        let fixture = try Fixture(entries: 5)
        defer { fixture.close() }
        let draft = HistoryLimitsDraft(model: fixture.model, delay: .seconds(3600))
        draft.change(.init(entries: 5, days: 30))
        XCTAssertNil(draft.value); XCTAssertNil(draft.question)
        XCTAssertEqual(fixture.model.configuration.preferences.historyLimit, 5)
        draft.change(.init(entries: 5, days: 7))
        XCTAssertEqual(fixture.model.configuration.preferences.historyRetentionDays, 7)
        draft.change(.init(entries: 120, days: 7))
        XCTAssertEqual(fixture.model.configuration.preferences.historyLimit, 120, "Raising a limit never needs an answer")
        XCTAssertEqual(fixture.model.history.count, 5)
        XCTAssertNil(fixture.model.errorMessage)
    }

    func testStepsAreAskedAboutOnceWhenTheyPause() async throws {
        let desk = Desk(entries: 10)
        let draft = desk.draft(delay: .milliseconds(20))
        for limit in stride(from: 9, through: 4, by: -1) { draft.change(.init(entries: limit, days: 30)) }
        XCTAssertNil(draft.question, "Holding the stepper must not ask at every step")
        XCTAssertEqual(draft.value?.entries, 4)
        for _ in 0..<1000 where draft.question == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(draft.question, .init(limits: .init(entries: 4, days: 30), dropped: 6))
        XCTAssertEqual(desk.saves, [])
    }

    func testTheQuestionKeepsItsCountWhileItIsAsked() {
        let desk = Desk(entries: 10)
        let draft = desk.draft(delay: .seconds(3600))
        draft.change(.init(entries: 8, days: 30)); draft.ask()
        // A stepper that is still held when the question appears.
        draft.change(.init(entries: 2, days: 30))
        XCTAssertEqual(draft.question, .init(limits: .init(entries: 8, days: 30), dropped: 2))
        XCTAssertEqual(draft.value, .init(entries: 8, days: 30))
        draft.confirm(draft.question!)
        XCTAssertEqual(desk.saves, [.init(entries: 8, days: 30)], "What is deleted must be what was asked about")
    }

    func testSteppingBackToWhatFitsNeedsNoAnswer() {
        let desk = Desk(entries: 10)
        let draft = desk.draft(delay: .seconds(3600))
        draft.change(.init(entries: 9, days: 30))
        draft.change(.init(entries: 200, days: 30))
        XCTAssertNil(draft.value, "Back at the saved limits there is nothing left to ask or to save")
        draft.ask()
        XCTAssertNil(draft.question)
        XCTAssertEqual(desk.saves, [])
        draft.change(.init(entries: 9, days: 30))
        draft.change(.init(entries: 10, days: 30))
        XCTAssertEqual(desk.saves, [.init(entries: 10, days: 30)])
        XCTAssertNil(draft.value)
    }

    func testHistoryClearedWhileTheStepperMovedIsNotAskedAbout() {
        let desk = Desk(entries: 10)
        let draft = desk.draft(delay: .seconds(3600))
        draft.change(.init(entries: 5, days: 30))
        desk.entries = 0
        draft.ask()
        XCTAssertNil(draft.question)
        XCTAssertEqual(desk.saves, [.init(entries: 5, days: 30)])
    }

    func testCancelledStepsAreNeitherAskedAboutNorSaved() async throws {
        let desk = Desk(entries: 10)
        let draft = desk.draft(delay: .milliseconds(20))
        draft.change(.init(entries: 5, days: 30))
        // The page or its window closed before the stepping paused.
        draft.cancel()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(draft.question); XCTAssertNil(draft.value)
        XCTAssertEqual(desk.saves, [])
    }

    /// Stands in for the saved limits and a history that holds one entry a day.
    private final class Desk {
        var stored = HistoryLimitsDraft.Limits(entries: 200, days: 30)
        var entries: Int
        var saves: [HistoryLimitsDraft.Limits] = []
        init(entries: Int) { self.entries = entries }

        @MainActor func draft(delay: Duration) -> HistoryLimitsDraft {
            HistoryLimitsDraft(delay: delay, stored: { self.stored },
                               dropped: { max(0, self.kept(self.stored) - self.kept($0)) }) { limits in
                self.saves.append(limits); self.stored = limits
            }
        }
        private func kept(_ limits: HistoryLimitsDraft.Limits) -> Int { min(entries, limits.entries, limits.days) }
    }

    /// A model with saved history, one entry a day, newest first.
    @MainActor private struct Fixture {
        let directory: URL
        let model: AppModel
        let entries: [HistoryEntry]
        let saved: Data

        init(entries count: Int) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            var preferences = Preferences(); preferences.historyEnabled = true
            let now = Date()
            entries = (0..<count).map {
                HistoryEntry(timestamp: now.addingTimeInterval(-Double($0) * 86_400 - 60), originalText: "Original \($0)", processedText: "Result \($0)",
                             ruleName: "Proofread", providerName: "Local", model: "test")
            }
            for entry in entries { try HistoryStore(directory: directory).append(entry, preferences: preferences) }
            model = AppModel(dataDirectory: directory, registerShortcuts: false)
            saved = try Data(contentsOf: model.historyFileURL)
        }

        func close() { try? FileManager.default.removeItem(at: directory) }
    }
}
