import XCTest
@testable import FrogCore

final class RuleConfigurationTests: XCTestCase {
    func testMigrationFreezesEffectiveModelsAndRecordingOptions() throws {
        var config = Configuration()
        let provider = ProviderConfiguration(model: "first", models: [.init(id: "first"), .init(id: "second")])
        config.providers = [provider]; config.defaultProviderID = provider.id
        var text = Rule(); text.model = "second"
        var speech = Rule.dictationPreset; speech.hotkey = Hotkey(keyCode: 12, modifiers: 4096)
        config.rules = [text, speech]
        var workflow = WorkflowPreferences(); workflow.audioModelID = "whisper-base"; workflow.recordingMode = .hold; workflow.output = .paste; workflow.transcriptionLanguage = "de"; workflow.showDictationPopup = false
        config.preferences.workflows = workflow
        config.adoptExplicitRuleSettings(installed: ["whisper-base"])
        XCTAssertEqual(config.rules[0].providerID, provider.id)
        XCTAssertEqual(config.rules[0].model, "second")
        XCTAssertEqual(config.rules[1].action?.audioModelID, "whisper-base")
        XCTAssertEqual(config.rules[1].action?.recordingMode, .hold)
        XCTAssertEqual(config.rules[1].action?.output, .paste)
        XCTAssertEqual(config.rules[1].action?.transcriptionLanguage, "de")
        XCTAssertEqual(config.rules[1].action?.showRecordingPopup, false)
        XCTAssertEqual(config.rules[1].hotkey, speech.hotkey)
        let migrated = config
        config.adoptExplicitRuleSettings(installed: [])
        XCTAssertEqual(config, migrated)
        XCTAssertEqual(try ConfigurationFile.decode(ConfigurationFile.encode(config)), config)
    }

    func testFirstModelConfiguresFactoryRulesButLaterAdditionsOnlyPreselectNewRules() {
        var config = Configuration(); config.adoptExplicitRuleSettings(installed: [])
        XCTAssertTrue(config.rules.allSatisfy { $0.providerID == nil && $0.action?.localTextModelID == nil })
        let first = RuleModelSelection(modelID: "qwen-0.6b", category: .text)
        let second = RuleModelSelection(modelID: "qwen-4b", category: .text)
        config.modelAdded(first)
        config.modelAdded(second)
        XCTAssertTrue(config.rules.allSatisfy { $0.action?.localTextModelID == first.modelID })
        let new = config.newRule(category: .text, installed: [first.modelID, second.modelID])
        XCTAssertEqual(new.action?.localTextModelID, second.modelID)
        XCTAssertFalse(new.preset); XCTAssertNil(new.hotkey)
        let afterDeletion = config.newRule(category: .text, installed: [first.modelID])
        XCTAssertEqual(afterDeletion.action?.localTextModelID, first.modelID)
    }

    func testAudioSelectionIsIndependentOfCleanupAndCategoryValidation() throws {
        var config = Configuration()
        let provider = ProviderConfiguration(kind: .openAI, model: "speech", models: [.init(id: "speech", category: .audio), .init(id: "text")])
        config.providers = [provider]
        var rule = Rule.dictationPreset
        RuleModelSelection(providerID: provider.id, modelID: "speech", category: .audio).apply(to: &rule)
        RuleModelSelection(modelID: "qwen-0.6b", category: .text).apply(to: &rule)
        config.rules = [rule]
        try ConfigurationFile.validate(config)
        XCTAssertEqual(rule.action?.audioProviderID, provider.id)
        XCTAssertEqual(rule.action?.audioModelID, "speech")
        XCTAssertEqual(rule.action?.localTextModelID, "qwen-0.6b")
        config.providers[0].kind = .anthropic
        XCTAssertThrowsError(try ConfigurationFile.validate(config))
        XCTAssertEqual(Rule.dictationPreset.hotkey, Hotkey(keyCode: 49, modifiers: 2048))
    }

    func testRemovedLocalTextFallsBackForTextAndCleanupWithoutCrossingIntoCloud() throws {
        var config = Configuration()
        let cloud = ProviderConfiguration(model: "cloud-text")
        config.providers = [cloud]
        var text = Rule()
        RuleModelSelection(modelID: "qwen-0.6b", category: .text).apply(to: &text)
        var audio = Rule.dictationPreset
        audio.action?.audioModelID = "whisper-tiny"; audio.action?.localTextModelID = "qwen-0.6b"
        config.rules = [text, audio, Rule(providerID: cloud.id, model: "cloud-text")]
        config.modelsRemoved([.init(modelID: "qwen-0.6b", category: .text)], installed: ["whisper-tiny", "qwen-1.7b"])
        XCTAssertEqual(config.rules[0].action?.localTextModelID, "qwen-1.7b")
        XCTAssertEqual(config.rules[1].action?.localTextModelID, "qwen-1.7b")
        XCTAssertEqual(config.rules[1].action?.audioModelID, "whisper-tiny")
        XCTAssertEqual(config.rules[2].providerID, cloud.id)
        config.modelsRemoved([.init(modelID: "qwen-1.7b", category: .text)], installed: ["whisper-tiny"])
        XCTAssertNil(config.rules[0].action?.localTextModelID)
        XCTAssertNil(config.rules[0].providerID)
        XCTAssertNil(config.rules[1].action?.localTextModelID)
        try ConfigurationFile.validate(config)
    }

    func testRemovedExternalAudioPrefersSameProviderAndCompatibleCategory() throws {
        var config = Configuration()
        let provider = ProviderConfiguration(model: "text", models: [.init(id: "text"), .init(id: "new-speech", category: .audio)])
        config.providers = [provider]
        var audio = Rule.dictationPreset
        audio.action?.audioModelID = "old-speech"; audio.action?.audioProviderID = provider.id
        config.rules = [audio]
        config.modelsRemoved([.init(providerID: provider.id, modelID: "old-speech", category: .audio)], installed: ["whisper-tiny"])
        XCTAssertEqual(config.rules[0].action?.audioModelID, "new-speech")
        XCTAssertEqual(config.rules[0].action?.audioProviderID, provider.id)
        config.providers = []
        config.modelsRemoved([.init(providerID: provider.id, modelID: "new-speech", category: .audio)], installed: ["whisper-tiny"])
        XCTAssertEqual(config.rules[0].action?.audioModelID, "whisper-tiny")
        XCTAssertNil(config.rules[0].action?.audioProviderID)
        try ConfigurationFile.validate(config)
    }
}
