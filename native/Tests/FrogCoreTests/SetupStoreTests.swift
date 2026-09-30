import XCTest
@testable import FrogCore

final class SetupStoreTests: XCTestCase {
    func testNewInstallationResumesUntilCompletedEvenAfterConfigurationIsCreated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SetupStore(directory: directory)
        XCTAssertTrue(try store.needsSetup(existingConfiguration: false))
        // Startup migrations can create a configuration before the assistant finishes.
        XCTAssertTrue(try SetupStore(directory: directory).needsSetup(existingConfiguration: true))
        try store.complete()
        XCTAssertFalse(try SetupStore(directory: directory).needsSetup(existingConfiguration: true))
    }

    func testExistingInstallationDoesNotGetAnUnexpectedFirstLaunchAssistant() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(try SetupStore(directory: directory).needsSetup(existingConfiguration: true))
        XCTAssertFalse(try SetupStore(directory: directory).needsSetup(existingConfiguration: false))
    }

    func testRecommendedPairContainsOneSpeechAndOneTextModel() {
        let models = LocalModelDescriptor.recommendedPair
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.filter { $0.kind == .audio }.count, 1)
        XCTAssertEqual(models.filter { $0.kind == .text }.count, 1)
        XCTAssertTrue(models.allSatisfy { LocalModelDescriptor.find($0.id) != nil })
    }
}
