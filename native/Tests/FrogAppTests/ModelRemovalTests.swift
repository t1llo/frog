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

    func testAnEmptyModelFolderLeavesRulesTheirModelsAndTheFormerFolderBringsThemBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in ["whisper-base", "qwen-0.6b"] {
            let folder = directory.appendingPathComponent("Models/\(id)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
            try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        }
        var configuration = Configuration()
        var audio = Rule.dictationPreset
        audio.action?.audioModelID = "whisper-base"; audio.action?.localTextModelID = "qwen-0.6b"; audio.action?.cleanup = true
        var text = Rule(preset: true)
        RuleModelSelection(modelID: "qwen-0.6b", category: .text).apply(to: &text)
        configuration.rules = [audio, text]; configuration.explicitRuleModels = true
        configuration.recentModels = [.init(modelID: "whisper-base", category: .audio), .init(modelID: "qwen-0.6b", category: .text)]
        let store = ConfigurationStore(directory: directory)
        try store.save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        let chosen = model.configuration
        XCTAssertEqual(chosen.rules[0].action?.audioModelID, "whisper-base")

        try await model.localModels.changeDirectory(to: directory.appendingPathComponent("Elsewhere"))
        XCTAssertTrue(model.localModels.installed.isEmpty)
        XCTAssertEqual(model.configuration, chosen, "A folder without models must not take the models out of the rules")
        XCTAssertEqual(try store.load(), chosen)
        XCTAssertEqual(model.ruleModelLabel(model.configuration.rules[0]), "Whisper Base · Not downloaded")
        // The rule says what is missing instead of recording into a model that is not there.
        model.startDictation(model.configuration.rules[0])
        XCTAssertFalse(model.dictation.active)
        XCTAssertTrue(model.errorMessage?.contains("Download this speech model") == true)
        // Editing such a rule in the meantime leaves its models as they are.
        var draft = model.configuration.rules[0]; draft.name = "Renamed"
        try model.saveRule(draft)
        XCTAssertEqual(try store.load().rules[0], draft)

        try await model.localModels.changeDirectory(to: directory.appendingPathComponent("Models"))
        XCTAssertEqual(model.localModels.installed, ["whisper-base", "qwen-0.6b"])
        XCTAssertEqual(model.configuration.rules, [draft, chosen.rules[1]])
        XCTAssertEqual(model.configuration.recentModels, chosen.recentModels)
        XCTAssertEqual(model.ruleModelLabel(model.configuration.rules[0]), "Whisper Base")
    }

    func testStartingWhileTheModelFolderIsOutOfReachLeavesRulesTheirModels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // As with a model folder on a disk that is not connected at this start.
        try JSONEncoder().encode(directory.appendingPathComponent("Unmounted/Models").path).write(to: directory.appendingPathComponent("model-storage.json"))
        var configuration = Configuration()
        var audio = Rule.dictationPreset
        audio.action?.audioModelID = "whisper-base"; audio.action?.localTextModelID = "qwen-0.6b"
        configuration.rules = [audio]; configuration.explicitRuleModels = true
        configuration.recentModels = [.init(modelID: "whisper-base", category: .audio)]
        let store = ConfigurationStore(directory: directory)
        try store.save(configuration)
        let saved = try store.load()
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        XCTAssertTrue(model.localModels.installed.isEmpty)
        XCTAssertEqual(model.configuration, saved)
        XCTAssertEqual(try store.load(), saved)
    }

    func testAMissingModelIsReplacedOnlyByAnInstalledModelOfItsKind() {
        var configuration = Configuration()
        var audio = Rule.dictationPreset
        audio.action?.audioModelID = "whisper-base"; audio.action?.localTextModelID = "qwen-0.6b"
        configuration.rules = [audio]
        configuration.recentModels = [.init(modelID: "whisper-base", category: .audio), .init(modelID: "qwen-0.6b", category: .text)]
        configuration.reconcileUnavailableModels(installed: ["whisper-tiny"])
        XCTAssertEqual(configuration.rules[0].action?.audioModelID, "whisper-tiny")
        XCTAssertEqual(configuration.rules[0].action?.localTextModelID, "qwen-0.6b", "No text model is installed to take its place")
        XCTAssertEqual(configuration.recentModels, [.init(modelID: "qwen-0.6b", category: .text)])
    }

    func testAnOpenRuleKeepsAModelThatIsOutOfReachButNotOneThatWasDeleted() {
        var saved = Configuration()
        var rule = Rule.dictationPreset; rule.action?.audioModelID = "whisper-base"
        saved.rules = [rule]
        var draft = rule; draft.name = "Unsaved edit"
        XCTAssertEqual(saved.reconcilingModels(in: draft, installed: []), draft)
        XCTAssertEqual(saved.reconcilingModels(in: draft, installed: ["whisper-tiny"]).action?.audioModelID, "whisper-tiny")
        // Deleting the last speech model takes it out of the saved rules. Saving the
        // draft afterwards must not put it back.
        saved.modelsRemoved([.init(modelID: "whisper-base", category: .audio)], installed: [])
        let reconciled = saved.reconcilingModels(in: draft, installed: [])
        XCTAssertNil(reconciled.action?.audioModelID)
        XCTAssertEqual(reconciled.name, "Unsaved edit")
        // A model the catalog no longer lists cannot come back, and a rule naming it is not valid.
        var unlisted = Rule.dictationPreset; unlisted.action?.audioModelID = "unlisted-speech"
        saved.rules = [unlisted]
        saved.reconcileUnavailableModels(installed: [])
        XCTAssertNil(saved.rules[0].action?.audioModelID)
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
