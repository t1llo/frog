import XCTest
import FrogCore
@testable import FrogApp

@MainActor final class UnreadableDocumentsTests: XCTestCase {
    private var root: URL!
    private var file: URL { root.appendingPathComponent("toolkit-documents.json") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testReadableItemsStayUsableBesideOnesThisVersionCannotReadAndTheNoticeOutlastsTheSave() async throws {
        let note = UtilityDocument(kind: .note, title: "Readable note"), script = UtilityDocument(kind: .script, title: "Readable script")
        var elements = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([note, UtilityDocument(kind: .note, title: "Later kind"), script])) as? [[String: Any]])
        elements[1]["kind"] = "laterKind"
        let original = try JSONSerialization.data(withJSONObject: elements)
        try original.write(to: file)

        let model = LocalDocuments(directory: root)
        await model.load()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.items, [note, script])
        XCTAssertNil(model.issue)
        let unreadable = try XCTUnwrap(model.unreadable)
        XCTAssertEqual(unreadable.count, 1); XCTAssertEqual(unreadable.total, 3)
        XCTAssertEqual(model.fileToReveal?.lastPathComponent, "toolkit-documents.json")

        model.add(UtilityDocument(kind: .note, title: "Added"))
        let flushed = await model.flush()
        XCTAssertTrue(flushed)
        XCTAssertNil(model.issue)
        XCTAssertEqual(model.unreadable, unreadable, "The notice stays after the save that leaves the items out of the file")
        XCTAssertEqual(model.fileToReveal?.lastPathComponent, unreadable.backup.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: unreadable.backup), original)
        XCTAssertEqual(try JSONDecoder().decode([UtilityDocument].self, from: Data(contentsOf: file)).map(\.title), ["Readable note", "Readable script", "Added"])
    }

    func testAFileThatCannotBeOpenedIsNamedCanBeRevealedAndIsNeverReplaced() async throws {
        let bytes = Data("not JSON".utf8)
        try bytes.write(to: file)
        let model = LocalDocuments(directory: root)
        await model.load()
        XCTAssertFalse(model.loaded)
        XCTAssertTrue(try XCTUnwrap(model.issue).contains(file.path), model.issue ?? "")
        XCTAssertNil(model.unreadable)
        XCTAssertEqual(model.fileToReveal?.lastPathComponent, "toolkit-documents.json")
        model.add(UtilityDocument(kind: .note, title: "Ignored"))
        let flushed = await model.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try Data(contentsOf: file), bytes)

        // Once the file is repaired, the same model opens it without a restart.
        try JSONEncoder().encode([UtilityDocument(kind: .note, title: "Repaired")]).write(to: file)
        await model.load()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.items.map(\.title), ["Repaired"])
        XCTAssertNil(model.issue)
        XCTAssertNil(model.fileToReveal)
    }
}
