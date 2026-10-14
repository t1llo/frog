import XCTest
import FrogCore
@testable import FrogApp

/// Provider keys kept in memory, so that a test never reaches the login Keychain.
final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: String] = [:]
    private var writesAllowed = Int.max

    subscript(id: UUID) -> String? { lock.withLock { keys[id] } }
    /// Lets this many more saves or deletions succeed; the ones after fail as a locked Keychain does.
    func allowWrites(_ count: Int) { lock.withLock { writesAllowed = count } }

    func read(providerID: UUID) throws -> String? { lock.withLock { keys[providerID] } }
    func save(_ key: String, providerID: UUID) throws { try write { keys[providerID] = key } }
    func delete(providerID: UUID) throws { try write { keys[providerID] = nil } }
    private func write(_ change: () -> Void) throws {
        try lock.withLock {
            guard writesAllowed > 0 else { throw FrogError.message("Your login keychain is locked. Unlock it and try again.") }
            writesAllowed -= 1
            change()
        }
    }
}

@MainActor
final class ProviderCredentialTests: XCTestCase {
    func testAKeyIsSavedReplacedAndCleared() throws {
        let store = MemoryCredentialStore()
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, credentials: store)
        let provider = ProviderConfiguration(kind: .openAI)
        try model.saveProvider(provider, apiKey: "sk-first", clearKey: false)
        XCTAssertEqual(store[provider.id], "sk-first")
        XCTAssertTrue(model.hasAPIKey(provider.id))
        try model.saveProvider(provider, apiKey: "sk-second", clearKey: false)
        XCTAssertEqual(store[provider.id], "sk-second")
        try model.saveProvider(provider, apiKey: nil, clearKey: false)
        XCTAssertEqual(store[provider.id], "sk-second", "Saving without a new key keeps the saved one")
        try model.saveProvider(provider, apiKey: nil, clearKey: true)
        XCTAssertNil(store[provider.id])
        XCTAssertFalse(model.hasAPIKey(provider.id))
    }

    func testAKeyChangeIsUndoneWhenTheSettingsCannotBeSaved() throws {
        let store = MemoryCredentialStore()
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, credentials: store)
        let provider = ProviderConfiguration(kind: .openAI)
        try model.saveProvider(provider, apiKey: "sk-saved", clearKey: false)
        let saved = model.configuration
        try editBehind(model)
        var renamed = provider; renamed.name = "Renamed"
        XCTAssertThrowsError(try model.saveProvider(renamed, apiKey: "sk-new", clearKey: false))
        XCTAssertEqual(store[provider.id], "sk-saved", "A replaced key comes back when the connection stays as it was")
        XCTAssertThrowsError(try model.saveProvider(renamed, apiKey: nil, clearKey: true))
        XCTAssertEqual(store[provider.id], "sk-saved", "A cleared key comes back when the connection stays as it was")
        let other = ProviderConfiguration(name: "Other", kind: .openAI)
        XCTAssertThrowsError(try model.saveProvider(other, apiKey: "sk-other", clearKey: false))
        XCTAssertNil(store[other.id], "No key stays behind for a connection that was not saved")
        XCTAssertEqual(model.configuration, saved)
        XCTAssertNil(model.errorMessage)
    }

    func testAKeyThatCannotBePutBackIsReported() throws {
        let store = MemoryCredentialStore()
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, credentials: store)
        let provider = ProviderConfiguration(kind: .openAI)
        try model.saveProvider(provider, apiKey: "sk-saved", clearKey: false)
        try editBehind(model)
        // The new key is saved; putting the previous one back fails.
        store.allowWrites(1)
        XCTAssertThrowsError(try model.saveProvider(provider, apiKey: "sk-new", clearKey: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed outside Frog"), error.localizedDescription)
        }
        XCTAssertEqual(store[provider.id], "sk-new")
        XCTAssertTrue(model.errorMessage?.contains("previous key could not be restored") == true, model.errorMessage ?? "no error")
    }

    func testDeletingAConnectionRemovesItsKeyOrKeepsTheConnectionWhileTheKeyStays() throws {
        let directory = try directory()
        let store = MemoryCredentialStore()
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, credentials: store)
        let first = ProviderConfiguration(name: "First", kind: .openAI)
        let second = ProviderConfiguration(name: "Second", kind: .openAI)
        try model.saveProvider(first, apiKey: "sk-first", clearKey: false)
        try model.saveProvider(second, apiKey: "sk-second", clearKey: false)
        try model.deleteProvider(id: first.id)
        XCTAssertNil(store[first.id])
        XCTAssertEqual(model.configuration.providers.map(\.id), [second.id])
        let kept = model.configuration
        store.allowWrites(0)
        XCTAssertThrowsError(try model.deleteProvider(id: second.id))
        XCTAssertEqual(store[second.id], "sk-second")
        XCTAssertEqual(model.configuration, kept, "A connection whose key could not be removed stays, so that it can be deleted again")
        XCTAssertEqual(try ConfigurationStore(directory: directory).load(), kept)
    }

    func testCodingToolsNeverUseTheCredentialStore() throws {
        let store = MemoryCredentialStore()
        store.allowWrites(0)
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, credentials: store)
        let tool = ProviderConfiguration(name: "Claude Code", kind: .claudeCode)
        XCTAssertThrowsError(try model.saveProvider(tool, apiKey: "sk-tool", clearKey: false))
        try model.saveProvider(tool, apiKey: nil, clearKey: false)
        XCTAssertFalse(model.hasAPIKey(tool.id))
        try model.deleteProvider(id: tool.id)
        XCTAssertTrue(model.configuration.providers.isEmpty)
    }

    func testRequestsAndConnectionTestsUseTheSavedKey() async throws {
        let store = MemoryCredentialStore()
        var keys: [String?] = []
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, complete: { _, _, _, key in
            keys.append(key); return "Done"
        }, credentials: store, writeClipboard: { _ in })
        let provider = ProviderConfiguration(kind: .openAI)
        try model.saveProvider(provider, apiKey: "sk-saved", clearKey: false)
        let rule = Rule(name: "Test", providerID: provider.id, model: provider.model)
        try model.saveRule(rule)
        model.processManual(text: "Sample", ruleID: rule.id)
        for _ in 0..<200 where model.isProcessing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isProcessing)
        _ = try await model.testProvider(provider, apiKey: nil)
        _ = try await model.testProvider(provider, apiKey: "sk-typed")
        XCTAssertEqual(keys, ["sk-saved", "sk-saved", "sk-typed"])
    }

    /// A connection with only speech models has no text model to ask. Its test checks the key
    /// with the service instead, and a missing key is named before any request.
    func testTestingASpeechOnlyConnectionAsksForItsKeyInsteadOfNamingLocalServers() async throws {
        let model = AppModel(dataDirectory: try directory(), registerShortcuts: false, complete: { _, _, _, _ in
            XCTFail("A speech-only connection has no text model to complete with"); return ""
        }, credentials: MemoryCredentialStore(), writeClipboard: { _ in })
        for kind in [ProviderKind.openAI, .gemini] {
            let provider = ProviderConfiguration(kind: kind, model: "speech-model", models: [ProviderModel(id: "speech-model", category: .audio)])
            do { _ = try await model.testProvider(provider, apiKey: nil); XCTFail("A connection without a key cannot be tested") }
            catch {
                XCTAssertFalse(error.localizedDescription.contains("Ollama"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("API key"), error.localizedDescription)
            }
        }
    }

    /// An edit in the configuration file that Frog has not reloaded makes its next save fail.
    private func editBehind(_ model: AppModel) throws {
        let file = model.configurationFileURL
        try Data((try String(contentsOf: file, encoding: .utf8) + "theme = nord\n").utf8).write(to: file)
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
