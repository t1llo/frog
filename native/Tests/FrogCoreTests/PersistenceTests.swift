import XCTest
@testable import FrogCore

final class PersistenceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-tests-\(UUID())")
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testMissingConfigurationIsDefaultWithoutWritingAndRoundTripsPrivately() throws {
        let store = ConfigurationStore(directory: directory)
        let defaults = try store.load()
        XCTAssertFalse(defaults.preferences.historyEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        var configuration = defaults
        configuration.providers = [ProviderConfiguration(name: "Local", kind: .ollama)]
        configuration.defaultProviderID = configuration.providers[0].id
        configuration.preferences.historyEnabled = true
        try store.save(configuration)
        XCTAssertEqual(try ConfigurationStore(directory: directory).load(), configuration)
        let file = directory.appendingPathComponent("config.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        configuration.rules[0].name = "Changed"
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["config", "config.json"])
    }

    func testCorruptAndFutureConfigurationsAreNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        let store = ConfigurationStore(directory: directory)
        var future = Configuration(); future.version = 99
        for bytes in [Data("{broken".utf8), Data("{}".utf8), try JSONEncoder().encode(future)] {
            try bytes.write(to: file)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(Configuration()))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testMigrationAndNewFilesKeepStableTargetsThroughPrivateVarAlias() throws {
        let path = directory.path
        let alias = path.hasPrefix("/private/var/") ? path : path.hasPrefix("/var/") ? "/private" + path : path
        let aliasedDirectory = URL(fileURLWithPath: alias, isDirectory: true)
        try FileManager.default.createDirectory(at: aliasedDirectory, withIntermediateDirectories: true)
        let original = Configuration()
        try ConfigurationFile.encode(original).write(to: aliasedDirectory.appendingPathComponent("config.json"))
        let store = ConfigurationStore(directory: aliasedDirectory)
        XCTAssertEqual(try store.load(), original)
        var edited = original; edited.preferences.historyLimit = 42
        try store.save(edited)
        XCTAssertEqual(try ConfigurationStore(directory: directory).load(), edited)

        let fresh = ConfigurationStore(directory: aliasedDirectory.appendingPathComponent("new-directory"))
        try fresh.save(original)
        XCTAssertEqual(try fresh.load(), original)
    }

    func testConfigurationPreservesSymlinksAndSharedDirectoryPermissions() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("original.json")
        let bytes = try JSONEncoder().encode(Configuration())
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("config.json"), withDestinationURL: target)
        let store = ConfigurationStore(directory: directory)
        let original = try store.load()
        let textTarget = directory.appendingPathComponent("dotfiles-config")
        try FileManager.default.moveItem(at: store.textFile, to: textTarget)
        try FileManager.default.createSymbolicLink(at: store.textFile, withDestinationURL: textTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        _ = try store.load()
        var changed = original; changed.preferences.historyLimit = 42
        try store.save(changed)
        XCTAssertEqual(try store.load(), changed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: store.file.path), target.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: store.textFile.path), textTarget.path)
        XCTAssertTrue(try String(contentsOf: textTarget).contains("history-limit = 42"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testNativeConfigurationMigratesWithoutRemovingPreviousFile() throws {
        let legacy = directory.appendingPathComponent("legacy")
        let current = directory.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        var original = Configuration(); original.rules[0].name = "My rule"
        let bytes = try ConfigurationFile.encode(original)
        let previous = legacy.appendingPathComponent("configuration.json")
        try bytes.write(to: previous)
        let store = ConfigurationStore(directory: current, legacyDirectory: legacy)
        XCTAssertTrue(store.hasExistingConfiguration)
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(try Data(contentsOf: previous), bytes)
        var changed = original; changed.rules[0].name = "Synced rule"
        try ConfigurationFile.encode(changed).write(to: current.appendingPathComponent("config.json"))
        XCTAssertEqual(try store.load(), changed)
    }

    func testPrototypeIsBackedUpButUnknownConfigIsNeverOverwrittenDuringMigration() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Configuration()
        try ConfigurationFile.encode(original).write(to: directory.appendingPathComponent("configuration.json"))
        let prototype = Data(#"{"globalHotkeys":{},"llm":{},"shortcuts":[],"textProcessing":{}}"#.utf8)
        let store = ConfigurationStore(directory: directory)
        try prototype.write(to: store.file)
        XCTAssertEqual(try store.load(), original)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("config-prototype-backup-") })
        XCTAssertEqual(try Data(contentsOf: backup), prototype)
        let unknown = Data("{\"otherApp\":true}".utf8)
        try unknown.write(to: store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.file), unknown)
    }

    func testHistoryDisabledPreservesRecordsAndDoesNotCreateFiles() throws {
        let store = HistoryStore(directory: directory)
        var preferences = Preferences()
        try store.append(entry(), preferences: preferences)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        preferences.historyEnabled = true
        let saved = entry()
        try store.append(saved, preferences: preferences)
        let file = directory.appendingPathComponent("history.json")
        let bytes = try Data(contentsOf: file)
        preferences.historyEnabled = false
        try store.append(entry(), preferences: preferences)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try store.load(preferences: preferences), [saved])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.delete(id: saved.id)
        XCTAssertEqual(try store.load(preferences: preferences), [])
    }

    func testInterruptedHistoryRoundTripsAndLateUpdatesCannotRestoreDeletedEntries() throws {
        let store = HistoryStore(directory: directory)
        var preferences = Preferences(); preferences.historyEnabled = true
        let legacy = entry()
        XCTAssertNil(try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(legacy)).interruption)
        var interrupted = entry(); interrupted.category = .audio
        interrupted.interruption = .escape; interrupted.transcriptState = .partial
        try store.append(interrupted, preferences: preferences)
        XCTAssertEqual(try store.load(preferences: preferences), [interrupted])
        interrupted.processedText = "Recovered transcript"; interrupted.transcriptState = .complete
        XCTAssertTrue(try store.update(interrupted, preferences: preferences))
        XCTAssertEqual(try store.load(preferences: preferences), [interrupted])
        try store.delete(id: interrupted.id)
        XCTAssertFalse(try store.update(interrupted, preferences: preferences))
        XCTAssertTrue(try store.load(preferences: preferences).isEmpty)
        try store.append(interrupted, preferences: preferences)
        preferences.historyEnabled = false
        interrupted.processedText = "Disabled history must not change"
        XCTAssertFalse(try store.update(interrupted, preferences: preferences))
        XCTAssertEqual(try store.load(preferences: preferences).first?.processedText, "Recovered transcript")
    }

    func testHistoryBoundsRetentionOrderingDeduplicationAndClear() throws {
        let store = HistoryStore(directory: directory)
        var preferences = Preferences(); preferences.historyEnabled = true
        let now = Date()
        var entries = (0..<205).map { entry(timestamp: now.addingTimeInterval(-Double($0))) }
        entries.append(entry(timestamp: now.addingTimeInterval(-31 * 86_400)))
        entries.append(entries[0])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries.reversed()).write(to: directory.appendingPathComponent("history.json"))
        preferences.historyLimit = Int.max; preferences.historyRetentionDays = Int.max
        let loaded = try store.load(preferences: preferences)
        XCTAssertEqual(loaded, Array(entries.prefix(200)))
        preferences.historyLimit = 3
        XCTAssertEqual(try store.load(preferences: preferences), Array(entries.prefix(3)))
        var replacement = entries[0]; replacement.processedText = "Updated"
        try store.append(replacement, preferences: preferences)
        XCTAssertEqual(try store.load(preferences: preferences).first, replacement)
        preferences.historyLimit = Int.min; preferences.historyRetentionDays = Int.min
        XCTAssertEqual(try store.load(preferences: preferences).count, 1)
        try store.clear(); try store.clear()
        XCTAssertEqual(try store.load(preferences: preferences), [])
    }

    func testExpiredHistoryPrunedEvenWhenRecordingOffAndCorruptionPreserved() throws {
        let store = HistoryStore(directory: directory)
        var preferences = Preferences(); preferences.historyEnabled = true
        try store.append(entry(timestamp: Date().addingTimeInterval(-3 * 86_400)), preferences: preferences)
        preferences.historyEnabled = false; preferences.historyRetentionDays = 1
        XCTAssertEqual(try store.load(preferences: preferences), [])
        let file = directory.appendingPathComponent("history.json")
        let corrupt = Data("not json".utf8); try corrupt.write(to: file)
        XCTAssertThrowsError(try store.load(preferences: preferences))
        preferences.historyEnabled = true
        XCTAssertThrowsError(try store.append(entry(), preferences: preferences))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        try store.clear()
        XCTAssertEqual(try store.load(preferences: preferences), [])
    }

    func testConcurrentStoreInstancesDoNotLoseHistory() throws {
        let entries = (0..<40).map { _ in entry() }
        let directory = directory!
        DispatchQueue.concurrentPerform(iterations: entries.count) { index in
            var preferences = Preferences(); preferences.historyEnabled = true
            do { try HistoryStore(directory: directory).append(entries[index], preferences: preferences) }
            catch { XCTFail("Append failed: \(error)") }
        }
        XCTAssertEqual(Set(try HistoryStore(directory: directory).load(preferences: Preferences()).map(\.id)), Set(entries.map(\.id)))
    }

    func testKeyValidationRejectsEmptyAndHeaderInjectionWithoutKeychainAccess() throws {
        XCTAssertEqual(try KeychainStore.validatedKey("  sk-test\n"), "sk-test")
        for key in ["", " \n", "sk-a\r\nx-injected: value", "a b", "a\u{0}b", String(repeating: "x", count: 8193)] {
            XCTAssertThrowsError(try KeychainStore.validatedKey(key))
        }
    }

    private func entry(timestamp: Date = Date()) -> HistoryEntry {
        HistoryEntry(timestamp: timestamp, originalText: "Original", processedText: "Output", ruleName: "Proofread", providerName: "Local", model: "test")
    }
}
