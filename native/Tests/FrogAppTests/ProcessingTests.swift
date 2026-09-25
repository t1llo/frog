import XCTest
import Combine
import FrogCore
@testable import FrogApp

@MainActor
final class ProcessingTests: XCTestCase {
    func testSeparateDefaultsPreserveLocalSelectionAndDisplayLegacyOverride() async throws {
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false)
        var provider = ProviderConfiguration(kind: .ollama)
        provider.models.append(ProviderModel(id: "other", name: "Other model"))
        try model.saveProvider(provider, apiKey: nil, clearKey: false)
        var prefs = model.configuration.preferences.workflowSettings
        prefs.defaultLocalTextModelID = "qwen-1.7b"
        prefs.textSource = .frog
        try model.saveWorkflowPreferences(prefs)
        try model.setDefaultProvider(id: provider.id, activate: false)
        XCTAssertEqual(try model.resolved(Rule()).model, "qwen-1.7b")
        try model.setDefaultProvider(id: provider.id)
        XCTAssertEqual(model.configuration.preferences.workflowSettings.defaultLocalTextModelID, "qwen-1.7b")
        let legacy = Rule(name: "Legacy override", model: "other")
        XCTAssertEqual(try model.resolved(legacy).model, "other")
        XCTAssertEqual(model.ruleModelLabel(legacy), provider.name + " · Other model")
    }
    func testShortcutProcessesOnlyCapturedSelectionReplacesAndPersistsHistory() async throws {
        let folder = try directory()
        let selection = FixtureSelection(text: "teh selected text")
        var requests = 0
        let model = AppModel(dataDirectory: folder, registerShortcuts: false, complete: { text, _, _, _ in
            requests += 1
            XCTAssertEqual(text, "teh selected text")
            return "the selected text"
        }, readKey: { _ in nil }, writeClipboard: { _ in XCTFail("Selection owns replacement clipboard") },
            captureSelection: { selection })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        var preferences = model.configuration.preferences
        preferences.historyEnabled = true
        try model.savePreferences(preferences)
        model.processSelection(ruleID: model.configuration.rules[0].id)
        try await waitUntilFinished(model)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(selection.replacement, "the selected text")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.history.count, 1)
        let saved = try HistoryStore(directory: folder).load(preferences: preferences)
        XCTAssertEqual(saved.first?.originalText, selection.text)
        XCTAssertEqual(saved.first?.processedText, selection.replacement)
    }

    func testFailedSelectionCaptureSendsNoRequestAndCreatesNoHistory() async throws {
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, complete: { _, _, _, _ in
            XCTFail("Capture failure must not send stale clipboard content"); return "Unexpected"
        }, readKey: { _ in nil }, writeClipboard: { _ in XCTFail("No result to copy") },
            captureSelection: { throw FrogError.message("No selection") }, notify: { _, _ in })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        var preferences = model.configuration.preferences
        preferences.historyEnabled = true
        try model.savePreferences(preferences)
        model.processSelection(ruleID: model.configuration.rules[0].id)
        try await waitUntilFinished(model)
        XCTAssertEqual(model.errorMessage, "No selection")
        XCTAssertTrue(model.history.isEmpty)
    }

    func testReplacementFailureStillRecordsCompletedTransformation() async throws {
        let selection = FixtureSelection(text: "original", failsReplacement: true)
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false,
            complete: { _, _, _, _ in "translated" }, readKey: { _ in nil },
            captureSelection: { selection }, notify: { _, _ in })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        var preferences = model.configuration.preferences
        preferences.historyEnabled = true
        try model.savePreferences(preferences)
        model.processSelection(ruleID: model.configuration.rules[0].id)
        try await waitUntilFinished(model)
        XCTAssertEqual(model.history.first?.processedText, "translated")
        XCTAssertNotNil(model.errorMessage)
    }

    func testUnchangedPermissionRefreshDoesNotInvalidateOpenMenus() async throws {
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, readAccessibility: { true })
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        model.refreshSystemStatus()
        model.refreshSystemStatus()
        XCTAssertEqual(updates, 0)
        withExtendedLifetime(subscription) {}
    }

    func testDeletingLastProviderResetsRuleOverridesAndKeepsRules() async throws {
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false)
        let provider = ProviderConfiguration(kind: .ollama)
        try model.saveProvider(provider, apiKey: nil, clearKey: false)
        let rule = Rule(name: "Keep me", providerID: provider.id, model: provider.model)
        try model.saveRule(rule)
        try model.deleteProvider(id: provider.id)
        XCTAssertTrue(model.configuration.providers.isEmpty)
        XCTAssertNil(model.configuration.defaultProviderID)
        let retained = try XCTUnwrap(model.configuration.rules.first { $0.id == rule.id })
        XCTAssertNil(retained.providerID)
        XCTAssertEqual(retained.model, "")
        XCTAssertEqual(retained.instructions, rule.instructions)
        try ConfigurationFile.validate(model.configuration)
    }
    // Async test entry points let older XCTest runners hop to the main actor.
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func waitUntilFinished(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if !model.isProcessing { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Processing did not finish")
    }

    func testExplicitRuleProviderAndModelOverrideAreUsed() async throws {
        var routed: ProviderConfiguration?
        var copied = ""
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, complete: { text, _, provider, _ in
            routed = provider
            return "Corrected: \(text)"
        }, readKey: { _ in nil }, writeClipboard: { copied = $0 })
        let first = ProviderConfiguration(name: "Default", kind: .ollama)
        var second = ProviderConfiguration(name: "Rule provider", kind: .ollama)
        second.models.append(ProviderModel(id: "custom-model", name: "Friendly custom name"))
        try model.saveProvider(first, apiKey: nil, clearKey: false)
        try model.saveProvider(second, apiKey: nil, clearKey: false)
        let rule = Rule(name: "Test", providerID: second.id, model: "custom-model")
        try model.saveRule(rule)
        model.processManual(text: "héllo\nworld", ruleID: rule.id)
        try await waitUntilFinished(model)
        XCTAssertEqual(routed?.id, second.id)
        XCTAssertEqual(routed?.model, "custom-model")
        XCTAssertEqual(copied, "Corrected: héllo\nworld")
        XCTAssertEqual(model.manualResult, copied)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testDisablingHistoryDuringRequestPreventsRecordingEvenIfReenabled() async throws {
        var continuation: CheckedContinuation<String, Error>?
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, complete: { _, _, _, _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }, readKey: { _ in nil }, writeClipboard: { _ in })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        var preferences = Preferences(); preferences.historyEnabled = true
        try model.savePreferences(preferences)
        let rule = model.configuration.rules[0]
        model.processManual(text: "original", ruleID: rule.id)
        for _ in 0..<100 { if continuation != nil { break }; await Task.yield() }
        XCTAssertNotNil(continuation)
        preferences.historyEnabled = false; try model.savePreferences(preferences)
        preferences.historyEnabled = true; try model.savePreferences(preferences)
        continuation?.resume(returning: "corrected")
        try await waitUntilFinished(model)
        XCTAssertEqual(model.manualResult, "corrected")
        XCTAssertTrue(model.history.isEmpty)
    }

    func testCancellationAndOverlappingRequestsDoNotPublishLateResult() async throws {
        var continuation: CheckedContinuation<String, Error>?
        var requests = 0
        var writes = 0
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, complete: { _, _, _, _ in
            requests += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, readKey: { _ in nil }, writeClipboard: { _ in writes += 1 })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        let rule = model.configuration.rules[0]
        model.processManual(text: "first", ruleID: rule.id)
        model.processManual(text: "second", ruleID: rule.id)
        for _ in 0..<100 { if continuation != nil { break }; await Task.yield() }
        model.cancelProcessing()
        continuation?.resume(returning: "late response")
        try await waitUntilFinished(model)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(model.manualResult.isEmpty)
        XCTAssertTrue(model.status.contains("Cancelled"))
    }

    func testUnknownExplicitProviderDoesNotFallBackToDefault() async throws {
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, readKey: { _ in nil }, writeClipboard: { _ in })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        XCTAssertThrowsError(try model.saveRule(Rule(providerID: UUID())))
    }

    func testImportReplacesSettingsAndRemapsUnrecognizedCredentialIdentities() async throws {
        let directory = try directory()
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil }, writeClipboard: { _ in })
        let existing = ProviderConfiguration(name: "Existing", kind: .ollama)
        try model.saveProvider(existing, apiKey: nil, clearKey: false)
        var imported = model.configuration
        // A changed endpoint must not inherit the saved connection's credential identity.
        imported.providers[0].endpoint = "http://localhost:11435"
        imported.rules = [Rule(name: "Imported rule", providerID: existing.id)]
        imported.preferences.historyLimit = 25
        try model.importConfiguration(imported)
        let provider = try XCTUnwrap(model.configuration.providers.first)
        XCTAssertNotEqual(provider.id, existing.id)
        XCTAssertEqual(model.configuration.defaultProviderID, provider.id)
        XCTAssertEqual(model.configuration.rules[0].providerID, provider.id)
        XCTAssertEqual(model.configuration.preferences.historyLimit, 25)
        XCTAssertEqual(try ConfigurationStore(directory: directory).load(), model.configuration)
        let unchanged = model.configuration
        try model.importConfiguration(unchanged)
        XCTAssertEqual(model.configuration, unchanged, "An unchanged known connection can keep its Keychain identity")
    }

    func testInvalidImportLeavesCurrentSettingsAndFileUntouched() async throws {
        let directory = try directory()
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil }, writeClipboard: { _ in })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        let original = model.configuration
        let file = directory.appendingPathComponent("configuration.json")
        let bytes = try Data(contentsOf: file)
        var invalid = original
        invalid.rules[0].hotkey = Hotkey(keyCode: 999, modifiers: 0)
        XCTAssertThrowsError(try model.importConfiguration(invalid))
        XCTAssertEqual(model.configuration, original)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testInvalidRuleCannotMakeConfigurationUnexportable() async throws {
        let directory = try directory()
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil }, writeClipboard: { _ in })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        let original = model.configuration
        let file = directory.appendingPathComponent("configuration.json")
        let bytes = try Data(contentsOf: file)
        let invalidRules = [
            Rule(instructions: String(repeating: "x", count: 100_001)),
            Rule(model: "model\nname"),
            Rule(hotkey: Hotkey(keyCode: 999, modifiers: 0))
        ]
        for rule in invalidRules { XCTAssertThrowsError(try model.saveRule(rule)) }
        XCTAssertEqual(model.configuration, original)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let exported = directory.appendingPathComponent("exported.json")
        try model.exportConfiguration(to: exported)
        XCTAssertEqual(try ConfigurationFile.read(from: exported), original)
    }

    func testDefaultProviderAndItsSelectedModelAreUsedWithoutOverride() async throws {
        var routed: ProviderConfiguration?
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, complete: { _, _, provider, _ in
            routed = provider; return "Done"
        }, readKey: { _ in nil }, writeClipboard: { _ in })
        let first = ProviderConfiguration(name: "First", kind: .ollama)
        var second = ProviderConfiguration(name: "Second", kind: .lmStudio, model: "local-id")
        second.models.append(ProviderModel(id: "second-id", name: "My writing model"))
        second.model = "second-id"
        try model.saveProvider(first, apiKey: nil, clearKey: false)
        try model.saveProvider(second, apiKey: nil, clearKey: false)
        try model.setDefaultProvider(id: second.id)
        model.processManual(text: "Test", ruleID: model.configuration.rules[0].id)
        try await waitUntilFinished(model)
        XCTAssertEqual(routed?.id, second.id)
        XCTAssertEqual(routed?.model, "second-id")
    }

    func testManualProviderAndModelChoicesDoNotMutateSavedRule() async throws {
        var routed: ProviderConfiguration?
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, complete: { _, _, provider, _ in
            routed = provider; return "Done"
        }, readKey: { _ in nil }, writeClipboard: { _ in })
        let first = ProviderConfiguration(name: "Rule provider", kind: .ollama)
        var second = ProviderConfiguration(name: "Draft provider", kind: .ollama)
        second.models.append(ProviderModel(id: "draft-model"))
        try model.saveProvider(first, apiKey: nil, clearKey: false)
        try model.saveProvider(second, apiKey: nil, clearKey: false)
        let rule = Rule(providerID: first.id, model: first.model)
        try model.saveRule(rule)
        let previous = model.configuration
        model.processManual(text: "Sample", ruleID: rule.id, providerID: second.id, modelID: "draft-model")
        try await waitUntilFinished(model)
        XCTAssertEqual(routed?.id, second.id)
        XCTAssertEqual(routed?.model, "draft-model")
        XCTAssertEqual(model.configuration, previous)
    }

    func testDeletingDefaultProviderResetsLegacyInheritedOverride() async throws {
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false)
        let first = ProviderConfiguration(kind: .ollama, model: "old-model")
        let second = ProviderConfiguration(kind: .ollama, model: "new-model")
        try model.saveProvider(first, apiKey: nil, clearKey: false)
        try model.saveProvider(second, apiKey: nil, clearKey: false)
        let rule = Rule(model: "old-model")
        try model.saveRule(rule)
        try model.deleteProvider(id: first.id)
        XCTAssertEqual(model.configuration.defaultProviderID, second.id)
        XCTAssertEqual(model.configuration.rules.first { $0.id == rule.id }?.model, "")
        try ConfigurationFile.validate(model.configuration)
    }

    func testRemovingModelUsedByRulePreservesConfiguration() async throws {
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, readKey: { _ in nil }, writeClipboard: { _ in })
        var provider = ProviderConfiguration(kind: .ollama)
        provider.models.append(ProviderModel(id: "custom"))
        try model.saveProvider(provider, apiKey: nil, clearKey: false)
        try model.saveRule(Rule(providerID: provider.id, model: "custom"))
        let previous = model.configuration
        provider.models.removeAll { $0.id == "custom" }
        XCTAssertThrowsError(try model.saveProvider(provider, apiKey: nil, clearKey: false))
        XCTAssertEqual(model.configuration, previous)
    }

    func testPermissionStatusUpdatesWithoutReactivatingWindowAndHandlesRevocation() async throws {
        var granted = false
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, readAccessibility: { granted })
        XCTAssertFalse(model.accessibilityGranted)
        let monitor = Task { await model.monitorSystemStatus() }
        defer { monitor.cancel() }
        await Task.yield()
        granted = true
        for _ in 0..<30 {
            if model.accessibilityGranted { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(model.accessibilityGranted)
        granted = false
        for _ in 0..<30 {
            if !model.accessibilityGranted { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.accessibilityGranted)
    }
}

@MainActor
private final class FixtureSelection: CapturedTextSelection {
    let text: String
    let failsReplacement: Bool
    var replacement: String?
    init(text: String, failsReplacement: Bool = false) { self.text = text; self.failsReplacement = failsReplacement }
    func replace(with text: String) async throws {
        if failsReplacement { throw FrogError.message("Target changed; result copied") }
        replacement = text
    }
}
