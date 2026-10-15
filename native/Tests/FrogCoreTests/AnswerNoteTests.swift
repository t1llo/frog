import XCTest
@testable import FrogCore

final class AnswerNoteTests: XCTestCase {
    private let zurich = TimeZone(identifier: "Europe/Zurich")!
    /// 2026-10-14 09:30 in Zurich.
    private let date = ISO8601DateFormatter().date(from: "2026-10-14T07:30:00Z")!

    private var example: AnswerNoteContent {
        AnswerNoteContent(ruleName: "Explain", selection: "river bank", modelLabel: "Qwen3 4B · Frog", application: "Safari",
                          source: "https://example.com/article", date: date,
                          turns: [AnswerTurn(question: "", answer: "A raised strip of land along a river.\n"),
                                  AnswerTurn(question: "And on a boat?", answer: "The side of the boat.")])
    }

    // MARK: File names

    func testAFileNameDropsCharactersFileNamesAndLinksCannotHold() {
        XCTAssertEqual(name("What is: a *river* bank? <x> | #tag ^ref [link] {y}"), "What is a river bank x tag ref link y.md")
        XCTAssertEqual(name("a/b\\c\td"), "abc d.md")
        XCTAssertEqual(name("\n\n   first   line  \nsecond line"), "first line.md")
        XCTAssertEqual(name("...hidden thing"), "hidden thing.md")
        XCTAssertEqual(name(". . .x"), "x.md")
    }

    func testAFileNameIsCutAtAWordBoundary() {
        let words = Array(repeating: "word", count: 20).joined(separator: " ")
        XCTAssertEqual(name(words), Array(repeating: "word", count: 12).joined(separator: " ") + ".md")
        let oneWord = String(repeating: "abcdefghij", count: 7)
        XCTAssertEqual(name(oneWord), String(oneWord.prefix(60)) + ".md")
    }

    func testAnEmptySelectionIsNamedAfterTheTime() {
        XCTAssertEqual(name("  \n \t "), "Answer 2026-10-14 0930.md")
        XCTAssertEqual(name("???"), "Answer 2026-10-14 0930.md")
    }

    func testATakenNameGetsTheNextNumberThenAShortIdentifier() {
        XCTAssertEqual(name("river bank", existing: ["river bank.md"]), "river bank 2.md")
        XCTAssertEqual(name("river bank", existing: ["River Bank.md", "river bank 2.md"]), "river bank 3.md")
        let all = Set(["river bank.md"] + (2...99).map { "river bank \($0).md" })
        let last = name("river bank", existing: all)
        XCTAssertNotNil(last.range(of: #"^river bank [0-9a-f]{8}\.md$"#, options: .regularExpression), last)
    }

    // MARK: Daily file

    func testThePatternBecomesTheDateInTheCalendarsTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zurich
        // Still the 13th in UTC, already the 14th in Zurich.
        let late = ISO8601DateFormatter().date(from: "2026-10-13T23:30:00Z")!
        XCTAssertEqual(try AnswerNote.expand(pattern: "Daily/YYYY-MM-DD.md", date: late, calendar: calendar), "Daily/2026-10-14.md")
        XCTAssertEqual(try AnswerNote.expand(pattern: "Journal/YYYY/MM-DD", date: date, calendar: calendar), "Journal/2026/10-14.md")
        XCTAssertEqual(try AnswerNote.expand(pattern: "Answers.markdown", date: date, calendar: calendar), "Answers.markdown")
        XCTAssertEqual(try AnswerNote.expand(pattern: String(repeating: "a", count: 252) + ".md", date: date, calendar: calendar).count, 255)
    }

    func testAPatternOutsideTheFolderOrNotMarkdownIsRefused() {
        let calendar = Calendar(identifier: .gregorian)
        for pattern in ["../x.md", "Daily/../x.md", "./x.md", "/abs.md", "~/x.md", "", "   ", "a//b.md", "Daily/",
                        "a\nb.md", String(repeating: "a", count: 253) + ".md"] {
            XCTAssertThrowsError(try AnswerNote.expand(pattern: pattern, date: date, calendar: calendar), pattern) {
                XCTAssertEqual($0.localizedDescription, "Enter a file path inside the notes folder, such as Daily/YYYY-MM-DD.md.", pattern)
            }
        }
        XCTAssertThrowsError(try AnswerNote.expand(pattern: "Daily/YYYY.txt", date: date, calendar: calendar)) {
            XCTAssertEqual($0.localizedDescription, "Choose a Markdown file (.md).")
        }
    }

    // MARK: Markdown

    func testANoteHasFrontMatterTheQuoteAndTheConversation() {
        XCTAssertEqual(AnswerNote.document(example, timeZone: zurich), """
        ---
        source: "https://example.com/article"
        app: "Safari"
        model: "Qwen3 4B · Frog"
        date: 2026-10-14T09:30:00+02:00
        tags: [frog, explain]
        ---

        > river bank

        A raised strip of land along a river.

        ## Follow-up: And on a boat?

        The side of the boat.

        """)
    }

    func testFrontMatterValuesAreQuotedOnOneLine() {
        var note = example
        note.source = #"C:\Docs\"Q""#
        note.application = "Safari\nTechnology\tPreview"
        note.ruleName = "My Rule!! 2"
        let document = AnswerNote.document(note, timeZone: zurich)
        XCTAssertTrue(document.contains("\nsource: \"C:\\\\Docs\\\\\\\"Q\\\"\"\n"), document)
        XCTAssertTrue(document.contains("\napp: \"Safari Technology Preview\"\n"), document)
        XCTAssertTrue(document.contains("\ntags: [frog, my-rule-2]\n"), document)

        note.source = nil
        note.application = String(repeating: "x", count: 400)
        let shorter = AnswerNote.document(note, timeZone: zurich)
        XCTAssertFalse(shorter.contains("source:"), shorter)
        XCTAssertTrue(shorter.contains("\napp: \"\(String(repeating: "x", count: 300))\"\n"), shorter)
        XCTAssertEqual(AnswerNote.tags(ruleName: "Frog"), ["frog"])
        XCTAssertEqual(AnswerNote.tags(ruleName: " ** "), ["frog", "answer"])
        XCTAssertEqual(AnswerNote.tags(ruleName: "2026"), ["frog", "answer-2026"])
    }

    func testALongSelectionIsQuotedShortenedOnEveryLine() {
        var note = example
        note.selection = "first\n\nthird\n" + String(repeating: "y", count: 3_000)
        let document = AnswerNote.document(note, timeZone: zurich)
        let quote = document.components(separatedBy: "---\n\n")[1].components(separatedBy: "\n\nA raised")[0]
        XCTAssertEqual(quote, "> first\n> \n> third\n> " + String(repeating: "y", count: 2_000 - 13) + "…")
    }

    func testTheSurroundingTextIsNeverWritten() {
        let rule = Rule(name: "Explain")
        var session = AnswerSession(rule: rule, modelName: "Qwen3 4B", modelLabel: "Qwen3 4B · Frog", selection: "river bank",
                                    context: "We sat on the river bank until the light went.", application: "Notes",
                                    source: nil, replyLanguage: "English")
        session.apply(.text("A raised strip."))
        session.complete()
        let fromSession = AnswerNoteContent(session: session, date: date)
        XCTAssertEqual(fromSession.turns, [AnswerTurn(question: "", answer: "A raised strip.")])
        XCTAssertFalse(AnswerNote.document(fromSession).contains("light went"))
        XCTAssertFalse(AnswerNote.section(fromSession).contains("light went"))

        var entry = HistoryEntry(answer: session, providerName: "Frog", model: "Qwen3 4B")
        entry.timestamp = date
        let fromEntry = AnswerNoteContent(entry: entry)
        XCTAssertEqual(fromEntry.modelLabel, "Qwen3 4B · Frog")
        XCTAssertEqual(fromEntry.turns, fromSession.turns)
        XCTAssertEqual(fromEntry.application, "Notes")
        XCTAssertFalse(AnswerNote.document(fromEntry).contains("light went"))
    }

    func testAStoppedAnswerKeepsItsText() {
        var session = AnswerSession(rule: Rule(name: "Explain"), modelName: "m", modelLabel: "m", selection: "x", context: nil,
                                    application: nil, source: nil, replyLanguage: "English")
        session.apply(.text("Half an"))
        session.stop()
        XCTAssertEqual(AnswerNoteContent(session: session, date: date).turns, [AnswerTurn(question: "", answer: "Half an")])
    }

    func testASectionHasTheTimeRuleAndSelectionInItsHeading() {
        XCTAssertEqual(AnswerNote.section(example, timeZone: zurich), """
        ## 09:30 · Explain: river bank

        *Safari · Qwen3 4B · Frog*

        > river bank

        A raised strip of land along a river.

        ### Follow-up: And on a boat?

        The side of the boat.

        """)
    }

    private func name(_ selection: String, existing: Set<String> = []) -> String {
        AnswerNote.fileName(selection: selection, date: date, existing: existing, timeZone: zurich)
    }
}
