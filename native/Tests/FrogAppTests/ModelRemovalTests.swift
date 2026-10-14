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

    func testChoosingTheSameModelFolderOnceItIsReachableBringsItsModelsBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = directory.appendingPathComponent("Unmounted/Models")
        try JSONEncoder().encode(folder.path).write(to: directory.appendingPathComponent("model-storage.json"))
        var configuration = Configuration()
        var audio = Rule.dictationPreset; audio.action?.audioModelID = "whisper-base"
        configuration.rules = [audio]; configuration.explicitRuleModels = true
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        XCTAssertTrue(model.localModels.installed.isEmpty)
        // The disk is connected after Frog started.
        let installed = folder.appendingPathComponent("whisper-base")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("fixture"), withIntermediateDirectories: true)
        try "fixture".write(to: installed.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)

        try await model.localModels.changeDirectory(to: folder)
        XCTAssertEqual(model.localModels.root.path, folder.path)
        XCTAssertEqual(model.localModels.installed, ["whisper-base"])
        XCTAssertEqual(model.ruleModelLabel(model.configuration.rules[0]), "Whisper Base")
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

    func testDeletingADownloadFirstSaysWhichModelHowLargeAndWhatBecomesOfItsRules() throws {
        let speech = try XCTUnwrap(LocalModelDescriptor.find("whisper-base"))
        var configuration = Configuration()
        var first = Rule.dictationPreset; first.action?.audioModelID = "whisper-base"
        var second = Rule.dictationPreset; second.action?.audioModelID = "whisper-base"; second.action?.localTextModelID = "qwen-0.6b"
        var other = Rule.dictationPreset; other.action?.audioModelID = "whisper-tiny"
        // A provider's model of the same name is not this download.
        var external = Rule.dictationPreset; external.action?.audioModelID = "whisper-base"; external.action?.audioProviderID = UUID()
        configuration.rules = [first, second, other, external]

        var prompt = ModelDeletionPrompt(speech, configuration: configuration, installed: ["whisper-base", "whisper-tiny", "qwen-0.6b"])
        XCTAssertEqual(prompt.title, "Delete Whisper Base?")
        XCTAssertEqual(prompt.message, "Its ≈150 MB download will be removed from this Mac. The 2 rules that use it will switch to Whisper Tiny.")
        prompt = ModelDeletionPrompt(speech, configuration: configuration, installed: ["whisper-base", "qwen-0.6b"])
        XCTAssertEqual(prompt.message, "Its ≈150 MB download will be removed from this Mac. The 2 rules that use it will be left without a speech model.")

        let text = try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b"))
        prompt = ModelDeletionPrompt(text, configuration: configuration, installed: ["whisper-base", "qwen-0.6b", "qwen-1.7b"])
        XCTAssertEqual(prompt.title, "Delete Qwen3 0.6B · 4-bit?")
        XCTAssertEqual(prompt.message, "Its ≈400 MB download will be removed from this Mac. The rule that uses it will switch to Qwen3 1.7B · 4-bit.")
        prompt = ModelDeletionPrompt(text, configuration: configuration, installed: ["qwen-0.6b"])
        XCTAssertEqual(prompt.message, "Its ≈400 MB download will be removed from this Mac. The rule that uses it will be left without a text model.")

        // A source added by link states no size.
        let custom = LocalModelDescriptor(id: "hf-custom", name: "Custom", kind: .text, repository: "someone/custom", size: "See source for size")
        configuration.localModels = [custom]
        prompt = ModelDeletionPrompt(custom, configuration: configuration, installed: ["hf-custom"])
        XCTAssertEqual(prompt.message, "Its download will be removed from this Mac. No rule uses it.")
        // What the question announces is what the deletion then does.
        configuration.modelsRemoved([.init(modelID: "whisper-base", category: .audio)], installed: ["whisper-tiny", "qwen-0.6b"])
        XCTAssertEqual(configuration.rules.map { $0.action?.audioModelID }, ["whisper-tiny", "whisper-tiny", "whisper-tiny", "whisper-base"])
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
