import XCTest
@testable import FrogCore

final class AnswerNoteWriterTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private let writer = AnswerNoteWriter()
    private let note = AnswerNoteContent(ruleName: "Explain", selection: "river bank", modelLabel: "Qwen3 4B · Frog",
                                         application: "Safari", source: nil, date: Date(),
                                         turns: [AnswerTurn(question: "", answer: "A raised strip of land along a river.")])

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("FrogNotes-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testOneNotePerAnswerNeverOverwritesAnother() throws {
        let first = try writer.save(note, folder: root, mode: .perAnswer, file: "", now: Date())
        XCTAssertEqual(first.lastPathComponent, "river bank.md")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), AnswerNote.document(note))
        let second = try writer.save(note, folder: root, mode: .perAnswer, file: "", now: Date())
        XCTAssertEqual(second.lastPathComponent, "river bank 2.md")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["river bank.md", "river bank 2.md"])
    }

    func testAddingToOneNoteCreatesItsFolderAndSeparatesSections() throws {
        let now = Date()
        let relative = try AnswerNote.expand(pattern: "Daily/YYYY-MM-DD.md", date: now, calendar: .current)
        let url = try writer.save(note, folder: root, mode: .append, file: "Daily/YYYY-MM-DD.md", now: now)
        XCTAssertEqual(url.resolvingSymlinksInPath().path, root.appendingPathComponent(relative).resolvingSymlinksInPath().path)
        let section = AnswerNote.section(note)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), section)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o644)

        _ = try writer.save(note, folder: root, mode: .append, file: "Daily/YYYY-MM-DD.md", now: now)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), section + "\n" + section)
    }

    func testAFileWithoutATrailingNewlineGetsOneAndABlankLine() throws {
        let file = root.appendingPathComponent("Answers.md")
        try Data("# Answers".utf8).write(to: file)
        _ = try writer.save(note, folder: root, mode: .append, file: "Answers", now: Date())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Answers\n\n" + AnswerNote.section(note))

        try Data("# Answers\n\n".utf8).write(to: file)
        _ = try writer.save(note, folder: root, mode: .append, file: "Answers.md", now: Date())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Answers\n\n" + AnswerNote.section(note))
    }

    func testAMissingFolderOrALargeFileIsRefused() throws {
        XCTAssertThrowsError(try writer.save(note, folder: base.appendingPathComponent("Gone"), mode: .perAnswer, file: "", now: Date())) {
            XCTAssertEqual($0.localizedDescription, "Choose a notes folder that exists.")
        }
        let large = root.appendingPathComponent("Large.md")
        try Data(count: 5 * 1024 * 1024 + 1).write(to: large)
        XCTAssertThrowsError(try writer.save(note, folder: root, mode: .append, file: "Large.md", now: Date())) {
            XCTAssertEqual($0.localizedDescription, "The note is larger than 5 MB. Choose another file.")
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: large.path)[.size] as? NSNumber, NSNumber(value: 5 * 1024 * 1024 + 1))
    }

    func testALinkOutOfTheFolderIsRefusedAndNothingIsWrittenThere() throws {
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Daily"), withDestinationURL: outside)
        XCTAssertThrowsError(try writer.save(note, folder: root, mode: .append, file: "Daily/YYYY-MM-DD.md", now: Date())) {
            XCTAssertEqual($0.localizedDescription, "The note would be written outside the notes folder.")
        }
        // A linked file is refused the same way.
        let target = outside.appendingPathComponent("Target.md")
        try Data("kept".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.md"), withDestinationURL: target)
        XCTAssertThrowsError(try writer.save(note, folder: root, mode: .append, file: "Linked.md", now: Date())) {
            XCTAssertEqual($0.localizedDescription, "The note would be written outside the notes folder.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["Target.md"])
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "kept")
    }
}
