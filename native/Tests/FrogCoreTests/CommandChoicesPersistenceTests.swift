import XCTest
@testable import FrogCore

final class CommandChoicesPersistenceTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-command-choices-tests-\(UUID())")
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testPrivateFileAndASecondCopyMergesOnWrite() throws {
        let first = CommandChoicesPersistence(directory: directory)
        XCTAssertEqual(try first.load(now: now), CommandChoices())
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.file.path))
        try first.record(typed: "ca", id: "app:Calendar", now: now)
        let file = try FileManager.default.attributesOfItem(atPath: first.file.path)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let second = CommandChoicesPersistence(directory: directory)
        let merged = try second.record(typed: "ca", id: "app:Calendar", now: now)
        XCTAssertEqual(merged.pairs.first?.strength, 2)
        XCTAssertEqual(try first.load(now: now).index(now: now).suggestions(for: "ca").latched, "app:Calendar")
        // Nothing to remember writes nothing new; forgetting a row rewrites the file without it.
        XCTAssertEqual(try second.record(typed: "secret", id: "clipboard:1", now: now), merged)
        XCTAssertTrue(try first.forget(id: "app:Calendar", now: now).items.isEmpty)
        XCTAssertEqual(try second.load(now: now), CommandChoices())
    }

    func testBrokenOrNewerFilesArePreservedUntilClear() throws {
        let store = CommandChoicesPersistence(directory: directory)
        try store.record(typed: "notes", id: "feature:notes", now: now)
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        XCTAssertNoThrow(try store.clear())

        var newer = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CommandChoices())) as? [String: Any])
        newer["version"] = 2
        for bytes in [Data("{broken".utf8), try JSONSerialization.data(withJSONObject: newer)] {
            try bytes.write(to: store.file)
            XCTAssertThrowsError(try store.load(now: now))
            XCTAssertThrowsError(try store.record(typed: "notes", id: "feature:notes", now: now))
            XCTAssertThrowsError(try store.forget(id: "feature:notes", now: now))
            XCTAssertEqual(try Data(contentsOf: store.file), bytes)
            try store.clear()
            XCTAssertEqual(try store.load(now: now), CommandChoices())
        }
    }

    func testTheFileStaysInsideItsLimitWithLongIDs() throws {
        let store = CommandChoicesPersistence(directory: directory)
        var choices = CommandChoices()
        let long = String(repeating: "x", count: 1_000)
        for number in 0..<500 {
            choices.pairs.append(.init(text: "t\(number)", id: "file:/\(number)/\(long)", strength: Double(number % 5) + 1, last: now))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(choices).write(to: store.file)
        let saved = try store.record(typed: "t1", id: "file:/1/\(long)", now: now)
        XCTAssertLessThanOrEqual(try Data(contentsOf: store.file).count, CommandChoices.Tuning.maxFileBytes)
        XCTAssertLessThan(saved.count, 500)
        XCTAssertTrue(saved.pairs.contains { $0.text == "t1" }, "the pick just made is the strongest")
        XCTAssertEqual(try store.load(now: now), saved)
    }
}
