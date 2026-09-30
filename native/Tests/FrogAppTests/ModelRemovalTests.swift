import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class ModelRemovalTests: XCTestCase {
    func testPreviouslyDeletedSelectionFallsBackWhenConfigurationLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Models/whisper-tiny")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
        try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        var config = Configuration()
        var audio = Rule.dictationPreset
        audio.action?.audioModelID = "whisper-base"
        config.rules = [audio]; config.explicitRuleModels = true
        let store = ConfigurationStore(directory: directory)
        try store.save(config)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        XCTAssertEqual(model.configuration.rules[0].action?.audioModelID, "whisper-tiny")
        XCTAssertEqual(try store.load().rules[0].action?.audioModelID, "whisper-tiny")
        XCTAssertTrue(model.localModels.loaded.isEmpty)
    }

    func testDeletingSelectedDownloadPersistsCompatibleFallbackWithoutChangingCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = ["whisper-base", "whisper-tiny", "qwen-0.6b"]
        for id in installed {
            let folder = directory.appendingPathComponent("Models/\(id)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
            try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        }
        var config = Configuration()
        var audio = Rule.dictationPreset
        audio.action?.audioModelID = "whisper-base"; audio.action?.localTextModelID = "qwen-0.6b"
        audio.action?.cleanup = true
        config.rules = [audio]; config.explicitRuleModels = true
        config.recentModels = [.init(modelID: "qwen-0.6b", category: .text)]
        try ConfigurationStore(directory: directory).save(config)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        try await model.deleteLocalModel(try XCTUnwrap(LocalModelDescriptor.find("whisper-base")))
        let saved = try ConfigurationStore(directory: directory).load()
        XCTAssertEqual(saved, model.configuration)
        XCTAssertEqual(saved.rules[0].action?.audioModelID, "whisper-tiny")
        XCTAssertEqual(saved.rules[0].action?.localTextModelID, "qwen-0.6b")
        XCTAssertEqual(saved.rules[0].action?.cleanup, true)
        XCTAssertEqual(model.localModels.installed, ["whisper-tiny", "qwen-0.6b"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Models/whisper-base").path))

        let before = model.configuration
        let hold = model.localModels.holdResidency()
        do { try await model.deleteLocalModel(try XCTUnwrap(LocalModelDescriptor.find("whisper-tiny"))); XCTFail("Cannot delete a model during recording") }
        catch { }
        XCTAssertEqual(model.configuration, before)
        model.localModels.releaseResidency(hold)
    }
}
