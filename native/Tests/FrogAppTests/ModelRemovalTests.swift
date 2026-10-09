import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class ModelRemovalTests: XCTestCase {
    func testChangingModelFolderRepairsSelectedSpeechModelBeforeNextRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let replacement = directory.appendingPathComponent("ReplacementModels")
        for (root, id) in [(directory.appendingPathComponent("Models"), "whisper-base"), (replacement, "whisper-tiny")] {
            let folder = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
            try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        }
        var configuration = Configuration()
        var rule = Rule.dictationPreset; rule.action?.audioModelID = "whisper-base"
        configuration.rules = [rule]; configuration.explicitRuleModels = true
        let store = ConfigurationStore(directory: directory)
        try store.save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        try await model.localModels.changeDirectory(to: replacement)
        XCTAssertEqual(model.configuration.rules[0].action?.audioModelID, "whisper-tiny")
        XCTAssertEqual(try store.load().rules[0].action?.audioModelID, "whisper-tiny")
    }

    func testDeletingAnAlreadyMissingDownloadRepairsTheRuleAndCanRemoveLastModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in ["whisper-base", "whisper-tiny"] {
            let folder = directory.appendingPathComponent("Models/\(id)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
            try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        }
        var configuration = Configuration()
        var rule = Rule.dictationPreset; rule.action?.audioModelID = "whisper-base"
        configuration.rules = [rule]; configuration.explicitRuleModels = true
        let store = ConfigurationStore(directory: directory)
        try store.save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Models/whisper-base"))
        try await model.deleteLocalModel(try XCTUnwrap(LocalModelDescriptor.find("whisper-base")))
        XCTAssertEqual(model.configuration.rules[0].action?.audioModelID, "whisper-tiny")
        try await model.deleteLocalModel(try XCTUnwrap(LocalModelDescriptor.find("whisper-tiny")))
        XCTAssertNil(model.configuration.rules[0].action?.audioModelID)
        var draft = model.configuration.rules[0]; draft.name = "Still editable"
        try model.saveRule(draft)
        XCTAssertEqual(try store.load().rules[0].name, "Still editable")
        model.startDictation(model.configuration.rules[0])
        XCTAssertFalse(model.dictation.active)
        XCTAssertTrue(model.errorMessage?.contains("Choose a speech model") == true)
    }

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
