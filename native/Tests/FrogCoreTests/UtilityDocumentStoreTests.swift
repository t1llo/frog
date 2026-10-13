import XCTest
@testable import FrogCore

final class UtilityDocumentStoreTests: XCTestCase {
    private var root: URL!
    private var file: URL { root.appendingPathComponent("toolkit-documents.json") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() {
        _ = chmod(root.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }
    private func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("toolkit-documents-backup-") }
    }
    /// Four saved items of which the second has a kind a later version added and the third lost its title.
    private func partlyUnreadable(_ first: UtilityDocument, _ last: UtilityDocument) throws -> Data {
        let filler = [UtilityDocument(kind: .shelf, title: "Later kind"), UtilityDocument(kind: .script, title: "Damaged")]
        var elements = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([first] + filler + [last])) as? [[String: Any]])
        elements[1]["kind"] = "laterKind"
        elements[2].removeValue(forKey: "title")
        return try JSONSerialization.data(withJSONObject: elements, options: [.prettyPrinted])
    }

    func testItemsThisVersionCannotReadAreLeftOutAndTheFileIsKeptBeforeItIsReplaced() async throws {
        let note = UtilityDocument(kind: .note, title: "Readable note", text: "text"), snippet = UtilityDocument(kind: .snippet, title: "Readable snippet")
        let original = try partlyUnreadable(note, snippet)
        try original.write(to: file)
        let store = UtilityDocumentStore(directory: root)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [note, snippet], "One unreadable item must not hide the others")
        // Reading changes nothing on disk, however often it happens.
        let again = try await store.load()
        XCTAssertEqual(again, loaded)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try backups(), [])
        let found = await store.unreadable
        let unreadable = try XCTUnwrap(found)
        XCTAssertEqual(unreadable.count, 2); XCTAssertEqual(unreadable.total, 4)
        XCTAssertTrue(unreadable.message.hasPrefix("2 of 4 items in "), unreadable.message)
        XCTAssertTrue(unreadable.message.contains("toolkit-documents.json"), unreadable.message)
        XCTAssertTrue(unreadable.message.contains(unreadable.backup.lastPathComponent), unreadable.message)

        let added = UtilityDocument(kind: .note, title: "Added")
        try await store.save(loaded + [added], revision: 1)
        let kept = try backups()
        XCTAssertEqual(kept.map(\.lastPathComponent), [unreadable.backup.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept.first)), original, "The copy holds the file exactly as it was")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: XCTUnwrap(kept.first).path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try JSONDecoder().decode([UtilityDocument].self, from: Data(contentsOf: file)), [note, snippet, added])
        // One copy is enough: later saves, and a later start, find a file that reads completely.
        try await store.save(loaded, revision: 2)
        XCTAssertEqual(try backups().count, 1)
        let relaunched = UtilityDocumentStore(directory: root)
        let reread = try await relaunched.load()
        XCTAssertEqual(reread, [note, snippet])
        let none = await relaunched.unreadable
        XCTAssertNil(none)
        try await relaunched.save(reread + [added], revision: 1)
        XCTAssertEqual(try backups().count, 1)
    }

    func testNothingIsSavedWhenTheUnreadableItemsCannotBeKeptFirst() async throws {
        let note = UtilityDocument(kind: .note, title: "Readable note")
        let original = try partlyUnreadable(note, note)
        try original.write(to: file)
        let store = UtilityDocumentStore(directory: root)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [note, note])
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        do {
            try await store.save([note], revision: 1)
            XCTFail("A save that would drop the unreadable items for good must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Nothing was saved"), error.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: file), original)
        // The same save goes through once the copy can be written.
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        try await store.save([note], revision: 1)
        XCTAssertEqual(try backups().count, 1)
        XCTAssertEqual(try JSONDecoder().decode([UtilityDocument].self, from: Data(contentsOf: file)), [note])
    }

    func testAFileThatIsNoListOfDocumentsIsNamedAndLeftAlone() async throws {
        let complete = try JSONEncoder().encode([UtilityDocument(kind: .note, title: "Note")])
        for bytes in [Data(complete.dropLast(9)), Data(#"{"documents":[]}"#.utf8), Data("not JSON".utf8)] {
            try bytes.write(to: file)
            let store = UtilityDocumentStore(directory: root)
            do {
                _ = try await store.load()
                XCTFail("A file that cannot be read as a list must not load as an empty one")
            } catch { XCTAssertTrue(error.localizedDescription.contains(file.path), error.localizedDescription) }
            let unreadable = await store.unreadable
            XCTAssertNil(unreadable)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try backups(), [])
        }
    }

    func testACompletelyReadableFileIsSavedWithoutACopy() async throws {
        let store = UtilityDocumentStore(directory: root)
        let empty = try await store.load()
        XCTAssertEqual(empty, [])
        let note = UtilityDocument(kind: .note, title: "Note")
        try await store.save([note], revision: 1)
        let relaunched = UtilityDocumentStore(directory: root)
        let loaded = try await relaunched.load()
        XCTAssertEqual(loaded, [note])
        let unreadable = await relaunched.unreadable
        XCTAssertNil(unreadable)
        try await relaunched.save([], revision: 1)
        XCTAssertEqual(try backups(), [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }
}
