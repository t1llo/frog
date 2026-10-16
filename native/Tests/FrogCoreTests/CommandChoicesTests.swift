import XCTest
@testable import FrogCore

final class CommandChoicesTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400

    func testKeyFoldsCollapsesAndCutsWithoutSplittingACharacter() {
        XCTAssertEqual(CommandChoices.key("  Café   Crème\tBrûlée "), "cafe creme brulee")
        XCTAssertEqual(CommandChoices.key(String(repeating: "a", count: 40)), String(repeating: "a", count: 32))
        let emoji = String(repeating: "a", count: 31) + "👨‍👩‍👧" + "b"
        XCTAssertEqual(CommandChoices.key(emoji), String(repeating: "a", count: 31) + "👨‍👩‍👧")
        XCTAssertEqual(CommandChoices.key("\u{1112}\u{1161}\u{11AB}").utf8.count, CommandChoices.key("한").utf8.count)
        // Empty text, such as a pick from the opening list, only strengthens the item. It still counts, so it can
        // be forgotten; a row also picked for typed text counts once.
        var choices = CommandChoices()
        choices.record(typed: "   ", id: "app:Calendar", now: start)
        XCTAssertTrue(choices.pairs.isEmpty)
        XCTAssertEqual(choices.items.map(\.id), ["app:Calendar"])
        XCTAssertEqual(choices.count, 1)
        choices.record(typed: "cal", id: "app:Calendar", now: start)
        choices.record(typed: "", id: "app:Notes", now: start)
        XCTAssertEqual(choices.count, 2)
    }

    func testStrengthHalvesEveryTwoWeeksIsCappedAndFadesAway() {
        XCTAssertEqual(CommandChoices.decayed(4, since: start, now: start.addingTimeInterval(14 * day)), 2, accuracy: 1e-9)
        XCTAssertEqual(CommandChoices.decayed(4, since: start, now: start.addingTimeInterval(-day)), 4)
        var choices = CommandChoices()
        for _ in 0..<12 { choices.record(typed: "cal", id: "app:Calendar", now: start) }
        XCTAssertEqual(choices.pairs.first?.strength, 5)
        XCTAssertEqual(choices.items.first?.strength, 10)
        var once = CommandChoices()
        once.record(typed: "cal", id: "app:Calendar", now: start)
        once.prune(now: start.addingTimeInterval(46 * day))
        XCTAssertEqual(once.count, 1)
        once.prune(now: start.addingTimeInterval(47 * day))
        XCTAssertEqual(once.count, 0)
        XCTAssertTrue(once.items.isEmpty)
    }

    func testLongerTextHelpsItsPrefixesAtHalfStrengthComparedOnBytes() {
        var choices = CommandChoices()
        for _ in 0..<3 { choices.record(typed: "calendar", id: "app:Calendar", now: start) }
        choices.record(typed: "cal", id: "app:Calculator", now: start)
        let index = choices.index(now: start)
        XCTAssertEqual(index.suggestions(for: "Calendar").leading, ["app:Calendar"])
        XCTAssertEqual(index.suggestions(for: "cal").leading, ["app:Calendar", "app:Calculator"])
        XCTAssertEqual(index.suggestions(for: "c").leading, ["app:Calendar", "app:Calculator"])
        XCTAssertEqual(index.suggestions(for: "calx").leading, [])
        XCTAssertNil(index.suggestions(for: "cal").latched)
        // 3 picks of "calendar" give "cal" 1.5; a fourth gives 2 and latches.
        choices.record(typed: "calendar", id: "app:Calendar", now: start)
        XCTAssertEqual(choices.index(now: start).suggestions(for: "cal").latched, "app:Calendar")
        XCTAssertEqual(choices.index(now: start).suggestions(for: "").leading, [])

        // A combining mark left after folding: "क" does not prefix "कि" as a String, but does as bytes,
        // and canonically equal spellings of one text are one key.
        var marks = CommandChoices()
        marks.record(typed: "कि", id: "app:Ki", now: start)
        marks.record(typed: "\u{1112}\u{1161}\u{11AB}", id: "app:Han", now: start)
        marks.record(typed: "한", id: "app:Han", now: start)
        XCTAssertEqual(marks.count, 2)
        let marked = marks.index(now: start)
        XCTAssertEqual(marked.suggestions(for: "क").leading, ["app:Ki"])
        XCTAssertEqual(marked.suggestions(for: "कि").leading, ["app:Ki"])
        XCTAssertEqual(marked.suggestions(for: "한").latched, "app:Han")
        // Diacritics fold away in both spellings.
        var accents = CommandChoices()
        accents.record(typed: "e\u{0301}t", id: "note:a", now: start)
        accents.record(typed: "ét", id: "note:a", now: start)
        XCTAssertEqual(accents.count, 1)
        XCTAssertEqual(accents.index(now: start).suggestions(for: "ET").latched, "note:a")
    }

    func testOneEstablishedRowLatchesAndTwoPicksOfAnotherMoveIt() {
        var choices = CommandChoices()
        choices.record(typed: "ca", id: "app:Calendar", now: start)
        XCTAssertNil(choices.index(now: start).suggestions(for: "ca").latched)
        choices.record(typed: "ca", id: "app:Calendar", now: start)
        XCTAssertEqual(choices.index(now: start).suggestions(for: "ca").latched, "app:Calendar")

        // Equal strength never latches.
        var tie = CommandChoices()
        tie.pairs = [.init(text: "ca", id: "a", strength: 2, last: start), .init(text: "ca", id: "b", strength: 2, last: start)]
        XCTAssertNil(tie.index(now: start).suggestions(for: "ca").latched)
        XCTAssertEqual(tie.index(now: start).suggestions(for: "ca").leading.count, 2)

        // Calculator at the cap; Calendar once: 1 against 2.5, the latch stays. Again: 2 against 1.25, it moves.
        var habit = CommandChoices()
        for _ in 0..<6 { habit.record(typed: "ca", id: "app:Calculator", now: start) }
        habit.record(typed: "ca", id: "app:Calendar", now: start)
        XCTAssertEqual(strength(habit, "ca", "app:Calendar"), 1)
        XCTAssertEqual(strength(habit, "ca", "app:Calculator"), 2.5)
        XCTAssertEqual(habit.index(now: start).suggestions(for: "ca").latched, "app:Calculator")
        habit.record(typed: "ca", id: "app:Calendar", now: start)
        XCTAssertEqual(strength(habit, "ca", "app:Calendar"), 2)
        XCTAssertEqual(strength(habit, "ca", "app:Calculator"), 1.25)
        let moved = habit.index(now: start).suggestions(for: "ca")
        XCTAssertEqual(moved.leading, ["app:Calendar", "app:Calculator"])
        XCTAssertEqual(moved.latched, "app:Calendar")

        // Alternating picks never establish either row.
        var alternating = CommandChoices()
        for round in 0..<10 {
            alternating.record(typed: "s", id: round.isMultiple(of: 2) ? "app:Slack" : "app:Safari", now: start)
            XCTAssertNil(alternating.index(now: start).suggestions(for: "s").latched, "\(round)")
        }
        XCTAssertEqual(alternating.index(now: start).suggestions(for: "s").leading, ["app:Safari", "app:Slack"])
        alternating.record(typed: "s", id: "app:Safari", now: start)
        XCTAssertEqual(alternating.index(now: start).suggestions(for: "s").latched, "app:Safari")
    }

    func testTwoPicksInOneSittingLatchThoughTheFirstFadedInBetween() throws {
        let minute: TimeInterval = 60
        var choices = CommandChoices()
        choices.record(typed: "ca", id: "app:Calendar", now: start)
        choices.record(typed: "ca", id: "app:Calendar", now: start.addingTimeInterval(minute))
        XCTAssertLessThan(try XCTUnwrap(strength(choices, "ca", "app:Calendar")), 2)
        XCTAssertEqual(choices.index(now: start.addingTimeInterval(10 * minute)).suggestions(for: "ca").latched, "app:Calendar")
        XCTAssertNil(choices.index(now: start.addingTimeInterval(day)).suggestions(for: "ca").latched, "Two picks fade within hours")
        choices.record(typed: "ca", id: "app:Calendar", now: start.addingTimeInterval(day))
        XCTAssertEqual(choices.index(now: start.addingTimeInterval(7 * day)).suggestions(for: "ca").latched, "app:Calendar",
                       "A third keeps it for about a week")

        // Two picks a week apart are not a habit yet.
        var apart = CommandChoices()
        apart.record(typed: "ca", id: "app:Calendar", now: start)
        apart.record(typed: "ca", id: "app:Calendar", now: start.addingTimeInterval(7 * day))
        XCTAssertNil(apart.index(now: start.addingTimeInterval(7 * day)).suggestions(for: "ca").latched)

        // A habit a day old moves to another row picked twice in one sitting.
        var habit = CommandChoices()
        for _ in 0..<6 { habit.record(typed: "ca", id: "app:Calculator", now: start) }
        habit.record(typed: "ca", id: "app:Calendar", now: start.addingTimeInterval(day))
        habit.record(typed: "ca", id: "app:Calendar", now: start.addingTimeInterval(day + minute))
        XCTAssertEqual(habit.index(now: start.addingTimeInterval(day + 2 * minute)).suggestions(for: "ca").latched, "app:Calendar")

        // Quick alternating picks still do not latch for a long while.
        var alternating = CommandChoices()
        for round in 0..<12 {
            let now = start.addingTimeInterval(Double(round) * minute)
            alternating.record(typed: "s", id: round.isMultiple(of: 2) ? "app:Slack" : "app:Safari", now: now)
            XCTAssertNil(alternating.index(now: now).suggestions(for: "s").latched, "\(round)")
        }
    }

    func testClipboardWindowsCalculationsAndHugeIDsAreNeverRemembered() {
        for id in ["clipboard:1", "window:2", "calculation:1+1", "", "file:/" + String(repeating: "x", count: 1_024)] {
            XCTAssertFalse(CommandChoices.isRememberable(id), id)
            var choices = CommandChoices()
            choices.record(typed: "secret", id: id, now: start)
            XCTAssertEqual(choices, CommandChoices())
        }
        XCTAssertTrue(CommandChoices.isRememberable("app:/Applications/Calendar.app"))
        XCTAssertTrue(CommandChoices.isRememberable("file:/" + String(repeating: "x", count: 1_018)))
    }

    func testCapsKeepTheStrongestAndTheEncodedChoicesStaySmall() throws {
        var choices = CommandChoices()
        for number in 0..<600 {
            choices.record(typed: "text \(number)", id: "file:/Users/Shared/Documents/report \(number).pdf", now: start.addingTimeInterval(Double(number)))
        }
        XCTAssertEqual(choices.count, 500)
        XCTAssertEqual(choices.items.count, 300)
        // Every pick has strength 1, so the older picks have faded a little more and leave first.
        XCTAssertEqual(Set(choices.pairs.map(\.text)), Set((100..<600).map { "text \($0)" }))
        XCTAssertEqual(choices.index(now: start.addingTimeInterval(600)).frequentItems(limit: 2),
                       ["file:/Users/Shared/Documents/report 599.pdf", "file:/Users/Shared/Documents/report 598.pdf"])
        XCTAssertLessThan(try JSONEncoder().encode(choices).count, CommandChoices.Tuning.maxFileBytes)
    }

    func testCodableRoundTripAndForget() throws {
        var choices = CommandChoices()
        choices.record(typed: "notes", id: "feature:notes", now: start)
        choices.record(typed: "budget", id: "file:/tmp/Budget.xlsx", now: start.addingTimeInterval(day))
        XCTAssertEqual(try JSONDecoder().decode(CommandChoices.self, from: JSONEncoder().encode(choices)), choices)
        let index = choices.index(now: start.addingTimeInterval(day))
        XCTAssertEqual(index.items(withPrefix: "file:"), ["file:/tmp/Budget.xlsx"])
        XCTAssertEqual(index.frequentItems(limit: 5), ["file:/tmp/Budget.xlsx", "feature:notes"])
        choices.forget(id: "file:/tmp/Budget.xlsx")
        XCTAssertEqual(choices.pairs.map(\.id), ["feature:notes"])
        XCTAssertEqual(choices.items.map(\.id), ["feature:notes"])
        XCTAssertTrue(CommandChoiceIndex.empty.suggestions(for: "notes").leading.isEmpty)
    }

    private func strength(_ choices: CommandChoices, _ text: String, _ id: String) -> Double? {
        choices.pairs.first { $0.text == text && $0.id == id }?.strength
    }
}
