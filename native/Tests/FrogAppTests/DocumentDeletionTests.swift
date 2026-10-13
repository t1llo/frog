import FrogCore
import XCTest
@testable import FrogApp

final class DocumentDeletionTests: XCTestCase {
    func testDeletingAnItemThatHoldsTextOrFilesAsksFirst() {
        XCTAssertTrue(UtilityDocument(kind: .note, title: "Untitled note", text: "Notes of a long meeting").deletionAsksFirst)
        XCTAssertTrue(UtilityDocument(kind: .script, title: "New script", text: "echo done").deletionAsksFirst)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("report.pdf")
        XCTAssertTrue(UtilityDocument(kind: .shelf, title: "report.pdf", files: [file]).deletionAsksFirst, "A shelf item for a file has no text of its own")
    }

    func testAnItemThatHoldsNothingIsDeletedWithoutAQuestion() {
        XCTAssertFalse(UtilityDocument(kind: .note, title: "Untitled note").deletionAsksFirst, "A note that was only just created")
        XCTAssertFalse(UtilityDocument(kind: .snippet, title: "New snippet", text: " \n\t").deletionAsksFirst, "Blank lines are nothing to lose")
    }
}
