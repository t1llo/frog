import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class ErrorPresentationTests: XCTestCase {
    func testBannerExpiresButLogRemainsAndNewErrorGetsItsOwnLifetime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, errorDisplayDuration: .milliseconds(20))
        model.report(FrogError.message("Could not raise window"))
        model.dismissError()
        model.report(FrogError.message("New error"))
        XCTAssertEqual(model.errorMessage, "New error")
        await model.waitForErrorDismissal()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.recentErrors.map(\.message), ["New error", "Could not raise window"])
        model.clearRecentErrors()
        XCTAssertTrue(model.recentErrors.isEmpty)
    }

    func testLogIsBoundedAndKeepsNewestErrors() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        for index in 0..<105 { model.report(FrogError.message("Error \(index)")) }
        XCTAssertEqual(model.recentErrors.count, 100)
        XCTAssertEqual(model.recentErrors.first?.message, "Error 104")
        XCTAssertEqual(model.recentErrors.last?.message, "Error 5")
        model.dismissError()
    }
}
