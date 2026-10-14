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

    func testMigrationThatCannotBeWrittenLeavesNoBackupBehind() throws {
        // A shortcut without Control, Option or Command decodes, but the text file has no spelling for it.
        var unwritable = Configuration()
        var workflow = WorkflowPreferences(); workflow.shortcutPanelHotkey = Hotkey(keyCode: 40, modifiers: 512)
        unwritable.preferences.workflows = workflow
        let bytes = try ConfigurationFile.encode(unwritable)

        let current = directory.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let store = ConfigurationStore(directory: current)
        try bytes.write(to: store.file)
        // Every launch repeats the attempt; none of them may add a file.
        for _ in 0..<3 { XCTAssertThrowsError(try store.load()) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: current.path), ["config.json"])
        XCTAssertEqual(try Data(contentsOf: store.file), bytes)

        let legacy = directory.appendingPathComponent("legacy")
        let empty = directory.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try bytes.write(to: legacy.appendingPathComponent("configuration.json"))
        let fresh = ConfigurationStore(directory: empty, legacyDirectory: legacy)
        for _ in 0..<3 { XCTAssertThrowsError(try fresh.load()) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
    }

    func testOnlyTheNewestBackupsOfEachKindAreKept() throws {
        let store = ConfigurationStore(directory: directory)
        var configuration = try store.load()
        try store.save(configuration)
        // Not a name Frog writes: it must survive however many backups follow.
        let foreign = directory.appendingPathComponent("configuration-backup-notes.json")
        try Data("mine".utf8).write(to: foreign)
        var written: [URL] = []
        for limit in 1...(ConfigurationStore.retainedBackups + 3) {
            configuration.preferences.historyLimit = limit
            written.append(try XCTUnwrap(store.replaceFromImport(configuration)))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("configuration-backup-") && $0 != foreign.lastPathComponent }
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, ConfigurationStore.retainedBackups)
        XCTAssertEqual(names.filter { $0.hasSuffix(".conf") }.count, ConfigurationStore.retainedBackups)
        XCTAssertEqual(written.map { FileManager.default.fileExists(atPath: $0.path) },
                       Array(repeating: false, count: 3) + Array(repeating: true, count: ConfigurationStore.retainedBackups),
                       "The oldest recovery copies go first")
        XCTAssertEqual(try Data(contentsOf: foreign), Data("mine".utf8))
        XCTAssertEqual(try store.load(), configuration)
    }

    func testSaveReadsTheFilesOnceBeforeItsFirstWriteAndStillRefusesAnOutsideEdit() throws {
        let store = ConfigurationStore(directory: directory)
        var configuration = try store.load()
        try store.save(configuration)
        var reads = store.snapshotReads
        // A preference lives in the text file alone, as every step of a dragged slider does.
        configuration.preferences.historyLimit = 42
        try store.save(configuration)
        XCTAssertEqual(store.snapshotReads - reads, 1)
        reads = store.snapshotReads
        // config.json is written first; the files are compared once more before the text file may follow.
        configuration.rules[0].name = "Renamed"
        configuration.preferences.historyLimit = 43
        try store.save(configuration)
        XCTAssertEqual(store.snapshotReads - reads, 2)
        XCTAssertEqual(try ConfigurationStore(directory: directory).load(), configuration)

        let outside = Data("history-limit = 7\n".utf8)
        try outside.write(to: store.textFile)
        let json = try Data(contentsOf: store.file)
        configuration.rules[0].name = "Lost"
        configuration.preferences.historyLimit = 44
        XCTAssertThrowsError(try store.save(configuration)) { XCTAssertTrue($0.localizedDescription.contains("Reload")) }
        XCTAssertEqual(try Data(contentsOf: store.textFile), outside)
        XCTAssertEqual(try Data(contentsOf: store.file), json)
    }

    func testOnlyAFailedReloadSaysThatPreviousSettingsWereKept() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kept = "Previous working settings were kept."
        let json = try TextConfiguration.companion(Configuration())
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        future["rules"] = [["id": UUID().uuidString]]
        let refused: [(text: String, json: Data)] = [("unknown-key = true\n", json), ("history-limit = 0\n", json),
                                                     ("", Data("{broken".utf8)), ("", try JSONSerialization.data(withJSONObject: future))]
        // At launch nothing has loaded yet, so no previous settings exist that could have been kept.
        for files in refused {
            let store = ConfigurationStore(directory: directory)
            try Data(files.text.utf8).write(to: store.textFile); try files.json.write(to: store.file)
            for _ in 0..<2 {
                XCTAssertThrowsError(try store.load()) {
                    XCTAssertTrue($0.localizedDescription.hasPrefix("config"), $0.localizedDescription)
                    XCTAssertFalse($0.localizedDescription.contains(kept), $0.localizedDescription)
                    XCTAssertTrue($0.localizedDescription.hasSuffix(" The files were left unchanged."), $0.localizedDescription)
                }
            }
            XCTAssertEqual(try Data(contentsOf: store.textFile), Data(files.text.utf8))
            XCTAssertEqual(try Data(contentsOf: store.file), files.json)
        }
        // Once a configuration has loaded, a reload that fails does keep it.
        let store = ConfigurationStore(directory: directory)
        try Data("history-limit = 42\n".utf8).write(to: store.textFile); try json.write(to: store.file)
        XCTAssertEqual(try store.load().preferences.historyLimit, 42)
        for files in refused {
            try Data(files.text.utf8).write(to: store.textFile); try files.json.write(to: store.file)
            XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0.localizedDescription.hasSuffix(" " + kept), $0.localizedDescription) }
        }
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

    func testCountingWhatLowerLimitsWouldDeleteLeavesHistoryAlone() throws {
        let store = HistoryStore(directory: directory)
        var preferences = Preferences(); preferences.historyEnabled = true
        let now = Date()
        for index in 0..<6 { try store.append(entry(timestamp: now.addingTimeInterval(-Double(index) * 86_400 - 60)), preferences: preferences) }
        let file = directory.appendingPathComponent("history.json")
        let saved = try Data(contentsOf: file)
        var lower = preferences; lower.historyLimit = 4
        XCTAssertEqual(try store.droppedCount(changing: preferences, to: lower), 2)
        lower.historyRetentionDays = 2
        XCTAssertEqual(try store.droppedCount(changing: preferences, to: lower), 4, "Entries older than the retention count as well")
        XCTAssertEqual(try store.droppedCount(changing: lower, to: preferences), 0, "Raising a limit deletes nothing")
        XCTAssertEqual(try store.droppedCount(changing: preferences, to: preferences), 0)
        XCTAssertEqual(try Data(contentsOf: file), saved, "Counting must not delete anything")
        XCTAssertEqual(try store.load(preferences: lower).count, 2, "The count is what saving the limits deletes")
        try store.clear()
        XCTAssertEqual(try store.droppedCount(changing: preferences, to: lower), 0)
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

    func testSavingHistoryDoesNotWaitForTheConfiguration() throws {
        let directory = directory!, entry = entry()
        var preferences = Preferences(); preferences.historyEnabled = true
        let appended = DispatchSemaphore(value: 0)
        var waited = DispatchTimeoutResult.timedOut
        // The configuration store is in the middle of a transaction while it validates what it read.
        _ = try ConfigurationStore(directory: directory).load { _ in
            DispatchQueue.global().async {
                do { try HistoryStore(directory: directory).append(entry, preferences: preferences) }
                catch { XCTFail("Append failed: \(error)") }
                appended.signal()
            }
            waited = appended.wait(timeout: .now() + 5)
        }
        if waited == .timedOut { appended.wait() }
        XCTAssertEqual(waited, .success)
        XCTAssertEqual(try HistoryStore(directory: directory).load(preferences: preferences).map(\.id), [entry.id])
    }

    func testHistoryTooLargeForItsFileDropsTheOldestInsteadOfRefusingTheNewest() throws {
        let store = HistoryStore(directory: directory)
        var preferences = Preferences(); preferences.historyEnabled = true
        // Two of these fit in the file, three do not.
        let text = String(repeating: "a", count: 11 * 1_024 * 1_024)
        let now = Date()
        let entries = (0..<3).map {
            HistoryEntry(timestamp: now.addingTimeInterval(Double($0) - 10), originalText: text, processedText: text, ruleName: "Proofread", providerName: "Local", model: "test")
        }
        try store.append(entries[0], preferences: preferences); try store.append(entries[1], preferences: preferences)
        XCTAssertEqual(try store.append(entries[2], preferences: preferences)?.map(\.id), [entries[2].id, entries[1].id])
        XCTAssertEqual(try store.load(preferences: preferences).map(\.id), [entries[2].id, entries[1].id])
        var grown = entries[1]; grown.processedText = text + text
        XCTAssertFalse(try store.update(grown, preferences: preferences))
        XCTAssertEqual(try store.load(preferences: preferences).map(\.id), [entries[2].id])
    }

    func testHistoryChangesReturnWhatIsKeptAfterwards() throws {
        let store = HistoryStore(directory: directory)
        var preferences = Preferences(); preferences.historyLimit = 2
        XCTAssertNil(try store.append(entry(), preferences: preferences))
        preferences.historyEnabled = true
        let now = Date()
        let entries = (0..<3).map { entry(timestamp: now.addingTimeInterval(Double($0) - 10)) }
        XCTAssertEqual(try store.append(entries[0], preferences: preferences), [entries[0]])
        XCTAssertEqual(try store.append(entries[1], preferences: preferences), [entries[1], entries[0]])
        XCTAssertEqual(try store.append(entries[2], preferences: preferences), [entries[2], entries[1]])
        XCTAssertEqual(try store.append(entry(timestamp: now.addingTimeInterval(-60)), preferences: preferences), [entries[2], entries[1]])
        XCTAssertEqual(try store.load(preferences: preferences), [entries[2], entries[1]])
        preferences.historyLimit = 200
        let expiring = entry(timestamp: now.addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(try store.append(expiring, preferences: preferences), [entries[2], entries[1], expiring])
        // Deleting with the preferences also prunes what loading would prune.
        var shorter = preferences; shorter.historyRetentionDays = 1
        XCTAssertEqual(try store.delete(id: entries[2].id, preferences: shorter), [entries[1]])
        XCTAssertEqual(try store.load(preferences: preferences), [entries[1]])
        XCTAssertEqual(try store.delete(id: UUID(), preferences: preferences), [entries[1]])
        XCTAssertEqual(try store.delete(id: entries[1].id), [])
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
