import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class ProcessingTests: XCTestCase {
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
        let second = ProviderConfiguration(name: "Rule provider", kind: .ollama)
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

    func testUnknownExplicitProviderDoesNotFallBackToDefault() throws {
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, readKey: { _ in nil }, writeClipboard: { _ in })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        XCTAssertThrowsError(try model.saveRule(Rule(providerID: UUID())))
    }

    func testImportReplacesSettingsAndRemapsUnrecognizedCredentialIdentities() throws {
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

    func testInvalidImportLeavesCurrentSettingsAndFileUntouched() throws {
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

    func testInvalidRuleCannotMakeConfigurationUnexportable() throws {
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
}
