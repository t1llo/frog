import XCTest
import FrogCore
@testable import FrogApp

/// Saving notes, snippets, shelf items and scripts, without a window.
@MainActor final class LocalDocumentsTests: XCTestCase {
    func testAnEditWhileQuitWaitsForTheSaveIsSavedAndQuitGoesAhead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = LocalDocuments(directory: root)
        await documents.load()
        documents.add(UtilityDocument(kind: .note, title: "Before quit"))
        let flushing = Task { await documents.flush() }
        // The quit is waiting for the save of the first edit when the second arrives, as a shelf drop still adding
        // its items would. Everything here runs on the main actor: yielding lets the save reach its delay and the quit
        // its wait for that save.
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(documents.needsFlush)
        documents.add(UtilityDocument(kind: .note, title: "During quit"))
        let saved = await flushing.value
        XCTAssertTrue(saved, "Nothing failed, so the quit must not be cancelled")
        XCTAssertFalse(documents.needsFlush)
        let stored = try await UtilityDocumentStore(directory: root).load()
        XCTAssertEqual(stored.map(\.title), ["Before quit", "During quit"])

        // A save that fails still ends the wait, and the quit is stopped.
        documents.add(UtilityDocument(kind: .note, title: "Too long", text: String(repeating: "a", count: 1_000_001)))
        let failed = await documents.flush()
        XCTAssertFalse(failed)
        XCTAssertNotNil(documents.issue)
    }
}
