import XCTest
@testable import FrogCore

private struct PhoneSettings: ConfigSection {
    var autoSend = true
    var port = 47321
}

@MainActor
final class ConfigStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("frog/config.toml") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigStoreTests-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
    }

    private func contents() throws -> String { try String(contentsOf: file, encoding: .utf8) }

    func testAMissingFileIsEmptyAndTheFirstSaveCreatesPrivateFiles() throws {
        let store = ConfigStore(fileURL: file)
        try store.load()
        XCTAssertEqual(store.document, ConfigDocument())
        XCTAssertEqual(try store.section("phone", as: PhoneSettings.self).value, PhoneSettings())
        var phone = PhoneSettings()
        phone.autoSend = false
        try store.update("phone", phone)
        XCTAssertEqual(try contents(), "[phone]\nauto-send = false\n")
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try store.section("phone", as: PhoneSettings.self).value, phone)
    }

    func testAnExistingFolderKeepsItsPermissions() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = ConfigStore(fileURL: file)
        try store.load()
        try store.setPlugin("phone", enabled: true)
        XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o755)
        XCTAssertEqual(try mode(file), 0o600)
    }

    func testSavesEditInPlaceAndKeepTheUsersFormatting() throws {
        try write("# mine\n[phone]\nauto-send = true   # yes\n\n[plugins]\nphone = true\n")
        let store = ConfigStore(fileURL: file)
        try store.load()
        try store.update("phone", PhoneSettings(autoSend: false))
        try store.setPlugin("writing", enabled: false)
        XCTAssertEqual(try contents(), "# mine\n[phone]\nauto-send = false   # yes\n\n[plugins]\nphone = true\nwriting = false\n")
        XCTAssertTrue(store.isPluginEnabled("phone", default: false))
        XCTAssertFalse(store.isPluginEnabled("writing", default: true))
        XCTAssertTrue(store.isPluginEnabled("dictation", default: true))
        XCTAssertEqual(try store.pluginSwitches(), ["phone": true, "writing": false])
    }

    func testAnExternalEditIsMergedBeforeSaving() throws {
        try write("[phone]\nauto-send = true\n")
        let store = ConfigStore(fileURL: file)
        try store.load()
        var changes: [ConfigDocument] = []
        store.onChange = { changes.append($0) }
        try write("# edited in an editor\n[phone]\nauto-send = true\nport = 1234\n")
        try store.update("phone", PhoneSettings(autoSend: false, port: 1234))
        XCTAssertEqual(try contents(), "# edited in an editor\n[phone]\nauto-send = false\nport = 1234\n")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(store.document.text, try contents())
        // The pending change is applied on top of the edit, so an edit to another key survives.
        try write("# edited in an editor\n[phone]\nauto-send = false\nport = 99\n")
        try store.setPlugin("phone", enabled: true)
        XCTAssertEqual(try contents(), "# edited in an editor\n[phone]\nauto-send = false\nport = 99\n\n[plugins]\nphone = true\n")
    }

    func testABrokenExternalEditIsNeverOverwritten() throws {
        try write("[phone]\nauto-send = true\n")
        let store = ConfigStore(fileURL: file)
        try store.load()
        let loaded = store.document
        try write("[phone]\nauto-send = \n")
        XCTAssertThrowsError(try store.update("phone", PhoneSettings(autoSend: false))) { error in
            let error = error as? ConfigError
            XCTAssertEqual(error?.kind, .externalEdit)
            XCTAssertEqual(error?.line, 2)
            XCTAssertTrue(error?.message.contains("line 2: expected a value after '='") == true, "\(String(describing: error))")
        }
        XCTAssertEqual(try contents(), "[phone]\nauto-send = \n")
        XCTAssertEqual(store.document, loaded)
    }

    func testLoadRefusesFilesOverFourMegabytes() throws {
        try write("# " + String(repeating: "x", count: ConfigFile.maximumBytes) + "\n")
        let store = ConfigStore(fileURL: file)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual(($0 as? ConfigError)?.kind, .file) }
    }

    func testASymlinkedFileIsReplacedAtItsDestination() throws {
        let real = directory.appendingPathComponent("dotfiles/frog.toml")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[phone]\nport = 1\n".utf8).write(to: real)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        let store = ConfigStore(fileURL: file)
        try store.load()
        try store.update("phone", PhoneSettings(autoSend: false, port: 1))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "[phone]\nport = 1\nauto-send = false\n")
    }

    func testTheWatcherReportsAnAtomicReplaceByAnEditor() async throws {
        try write("[phone]\nport = 1\n")
        let store = ConfigStore(fileURL: file, debounce: 0.05)
        try store.load()
        let changed = expectation(description: "onChange")
        store.onChange = { document in
            XCTAssertEqual(document.value(at: ["phone", "port"]), 2)
            changed.fulfill()
        }
        store.startWatching()
        try write("[phone]\nport = 2\n")
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(try store.section("phone", as: PhoneSettings.self).value.port, 2)

        // The new file is watched too.
        let again = expectation(description: "second edit")
        store.onChange = { _ in again.fulfill() }
        try write("[phone]\nport = 3\n")
        await fulfillment(of: [again], timeout: 5)
        XCTAssertEqual(store.document.value(at: ["phone", "port"]), 3)
    }

    func testTheWatcherDebouncesBurstsOfWrites() async throws {
        try write("[phone]\nport = 0\n")
        let store = ConfigStore(fileURL: file, debounce: 0.15)
        try store.load()
        var reported: [ConfigValue?] = []
        store.onChange = { reported.append($0.value(at: ["phone", "port"])) }
        store.startWatching()
        let handle = try FileHandle(forWritingTo: file)
        for port in 1...5 {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("[phone]\nport = \(port)\n".utf8))
            try await Task.sleep(for: .milliseconds(40))
        }
        try handle.close()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(reported, [5])
    }

    func testOwnSavesDoNotTriggerTheWatcher() async throws {
        try write("[phone]\nport = 1\n")
        let store = ConfigStore(fileURL: file, debounce: 0.05)
        try store.load()
        let changed = expectation(description: "no onChange")
        changed.isInverted = true
        store.onChange = { _ in changed.fulfill() }
        store.onError = { _ in changed.fulfill() }
        store.startWatching()
        try store.update("phone", PhoneSettings(autoSend: false, port: 5))
        try store.setPlugin("phone", enabled: true)
        await fulfillment(of: [changed], timeout: 0.8)
        XCTAssertEqual(try contents(), "[phone]\nport = 5\nauto-send = false\n\n[plugins]\nphone = true\n")
    }

    func testABrokenEditIsReportedOnceAndKeepsTheRunningConfiguration() async throws {
        try write("[phone]\nport = 1\n")
        let store = ConfigStore(fileURL: file, debounce: 0.05)
        try store.load()
        let loaded = store.document
        var errors: [ConfigError] = []
        let reported = expectation(description: "onError")
        store.onError = { errors.append($0); reported.fulfill() }
        store.startWatching()
        try write("[phone]\nport = = 2\n")
        await fulfillment(of: [reported], timeout: 5)
        XCTAssertEqual(errors.map(\.description), ["line 2: expected a value after '='"])
        XCTAssertEqual(store.document, loaded)
        // Touching the broken file again does not report it twice; fixing it is a change.
        let fixed = expectation(description: "onChange")
        store.onChange = { _ in fixed.fulfill() }
        try write("[phone]\nport = 2\n")
        await fulfillment(of: [fixed], timeout: 5)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(store.document.value(at: ["phone", "port"]), 2)
    }
}
