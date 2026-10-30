import CryptoKit
import XCTest
@testable import FrogCore

final class PluginManifestActionTests: XCTestCase {
    private func manifest(_ fields: [String: Any]) throws -> PluginManifest {
        var json: [String: Any] = ["id": "com.example.counter", "name": "Counter", "version": "1.0.0", "description": "Counts things."]
        for (key, value) in fields { json[key] = value }
        return try PluginManifest.decode(JSONSerialization.data(withJSONObject: json))
    }

    private func assertInvalid(_ fields: [String: Any], mentions word: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try manifest(fields), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(word), "\(error.localizedDescription)", file: file, line: line)
        }
    }

    func testActionsReadWithTypedParametersAndRoundTrip() throws {
        let plugin = try manifest(["actions": [
            ["id": "count", "title": "Count words", "effect": "read", "input": true],
            ["id": "pick", "title": "Pick", "effect": "write", "parameters": [
                ["name": "times", "type": "integer", "required": true, "help": "How often"],
                ["name": "mode", "type": "choice", "choices": ["fast", "slow"]],
                ["name": "note"],
            ]],
        ]])
        XCTAssertEqual(plugin.actions.map(\.id), ["count", "pick"])
        XCTAssertEqual(plugin.actions[0].effect, .read)
        XCTAssertEqual(plugin.actions[1].parameters.map(\.type), [.integer, .choice, .text])
        let again = try PluginManifest.decode(JSONEncoder().encode(plugin))
        XCTAssertEqual(again, plugin)
        XCTAssertLessThan(PluginManifestAction.Effect.read, .write)
        XCTAssertLessThan(PluginManifestAction.Effect.write, .network)
    }

    func testActionsAreChecked() {
        assertInvalid(["actions": [["id": "go", "title": "Go", "effect": "delete"]]], mentions: "read, write or network")
        assertInvalid(["actions": [["id": "Go", "title": "Go", "effect": "read"]]], mentions: "lowercase")
        assertInvalid(["actions": [["id": "go", "title": "Go", "effect": "network"]]], mentions: "network or ai permission")
        assertInvalid(["commands": [["id": "go", "title": "Go"]], "actions": [["id": "go", "title": "Go", "effect": "read"]]], mentions: "same id")
        assertInvalid(["actions": [["id": "go", "title": "Go", "effect": "read", "parameters": [["name": "stdin"]]]]], mentions: "stdin")
        assertInvalid(["actions": [["id": "go", "title": "Go", "effect": "read", "parameters": [["name": "a"], ["name": "a"]]]]], mentions: "twice")
        assertInvalid(["actions": [["id": "go", "title": "Go", "effect": "read", "parameters": [["name": "a", "type": "choice"]]]]], mentions: "choices")
        assertInvalid(["actions": [["id": "go", "title": "Go", "effect": "read", "parameters": [["name": "a", "choices": ["x"]]]]]], mentions: "Only a parameter")
        assertInvalid(["entry": NSNull(), "actions": [["id": "go", "title": "Go", "effect": "read"]]], mentions: "page")
        XCTAssertNoThrow(try manifest(["permissions": ["ai"], "actions": [["id": "go", "title": "Go", "effect": "network"]]]))
    }
}

final class PluginRegistryTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private func entry(_ id: String = "com.example.counter", version: String = "1.0.0") -> PluginRegistryEntry {
        PluginRegistryEntry(id: id, name: "Counter", summary: "Counts things.", version: version, author: "Ada",
                            permissions: ["clipboard-read"], manifest: "https://frog.example/plugins/files/\(id).json",
                            download: "https://frog.example/plugins/files/\(id)-\(version).frogplugin", sha256: String(repeating: "ab", count: 32))
    }

    private func signed(_ entry: PluginRegistryEntry, with key: Curve25519.Signing.PrivateKey? = nil) throws -> PluginRegistryEntry {
        var entry = entry
        entry.signature = try (key ?? self.key).signature(for: entry.signedMessage).base64EncodedString()
        return entry
    }

    private func data(_ entries: [PluginRegistryEntry]) throws -> Data { try JSONEncoder().encode(PluginRegistry(plugins: entries)) }

    func testTheSignedMessageIsFixedLinesInAFixedOrder() {
        let text = String(decoding: entry().signedMessage, as: UTF8.self)
        let expected = [
            "frog-plugin-registry-entry-v1", "id: com.example.counter", "name: Counter", "summary: Counts things.", "version: 1.0.0",
            "author: Ada", "symbol: ", "homepage: ", "frog: ", "permissions: clipboard-read",
            "manifest: https://frog.example/plugins/files/com.example.counter.json",
            "download: https://frog.example/plugins/files/com.example.counter-1.0.0.frogplugin",
            "sha256: " + String(repeating: "ab", count: 32),
        ]
        XCTAssertEqual(text, expected.joined(separator: "\n") + "\n")
    }

    func testOnlyEntriesSignedByATrustedKeyAreKept() throws {
        let good = try signed(entry())
        let otherKey = try signed(entry("com.example.other"), with: Curve25519.Signing.PrivateKey())
        var tampered = try signed(entry("com.example.tampered"))
        tampered.download = "https://evil.example/x.frogplugin"
        let unsigned = entry("com.example.unsigned")
        let result = try PluginRegistry.verified(data([good, otherKey, tampered, unsigned]), keys: [publicKey])
        XCTAssertEqual(result.entries.map(\.id), ["com.example.counter"])
        XCTAssertEqual(result.rejected, 3)
        XCTAssertEqual(try PluginRegistry.verified(data([good]), keys: []).entries, [], "With no trusted key nothing installs")
    }

    func testMalformedEntriesAreRejectedEvenWhenSigned() throws {
        var http = entry(); http.download = "http://frog.example/x.frogplugin"
        var shortHash = entry("com.example.hash"); shortHash.sha256 = "abc"
        var newline = entry("com.example.newline"); newline.summary = "Two\nlines"
        let result = try PluginRegistry.verified(data([try signed(http), try signed(shortHash), try signed(newline)]), keys: [publicKey])
        XCTAssertEqual(result.entries, [])
        XCTAssertEqual(result.rejected, 3)
    }

    func testTheNewestVersionOfAnIdWins() throws {
        let entries = [try signed(entry(version: "1.2.0")), try signed(entry(version: "1.10.0")), try signed(entry(version: "1.3.0"))]
        XCTAssertEqual(try PluginRegistry.verified(data(entries), keys: [publicKey]).entries.map(\.version), ["1.10.0"])
    }

    func testAnUnknownFormatIsRefused() {
        XCTAssertThrowsError(try PluginRegistry.verified(Data(#"{"format":2,"plugins":[]}"#.utf8), keys: [publicKey]))
        XCTAssertThrowsError(try PluginRegistry.verified(Data("nope".utf8), keys: [publicKey]))
    }

    func testSearchMatchesEveryWord() {
        XCTAssertTrue(entry().matches("count ada"))
        XCTAssertTrue(entry().matches("clipboard"))
        XCTAssertFalse(entry().matches("count bob"))
        XCTAssertTrue(entry().matches("  "))
    }
}
