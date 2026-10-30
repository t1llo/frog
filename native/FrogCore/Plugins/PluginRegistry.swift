import CryptoKit
import Foundation

/// One plugin in the directory's `registry.json`. The directory's owner signs every entry with an Ed25519 key, and
/// Frog installs only entries whose signature checks against a key it ships with, from a file whose SHA-256 is the
/// signed one.
public struct PluginRegistryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var version: String
    public var author: String
    public var symbol: String?
    public var homepage: String?
    /// The oldest Frog version the plugin works with.
    public var frog: String?
    public var permissions: [String]
    /// The plugin's `plugin.json`, to read before downloading.
    public var manifest: String
    /// The `.frogplugin` file.
    public var download: String
    public var sha256: String
    /// Base64 Ed25519 signature of `signedMessage`.
    public var signature: String

    public init(id: String, name: String, summary: String, version: String, author: String, symbol: String? = nil,
                homepage: String? = nil, frog: String? = nil, permissions: [String] = [], manifest: String, download: String,
                sha256: String, signature: String = "") {
        self.id = id; self.name = name; self.summary = summary; self.version = version; self.author = author
        self.symbol = symbol; self.homepage = homepage; self.frog = frog; self.permissions = permissions
        self.manifest = manifest; self.download = download; self.sha256 = sha256; self.signature = signature
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        summary = try values.decode(String.self, forKey: .summary)
        version = try values.decode(String.self, forKey: .version)
        author = try values.decode(String.self, forKey: .author)
        symbol = try values.decodeIfPresent(String.self, forKey: .symbol)
        homepage = try values.decodeIfPresent(String.self, forKey: .homepage)
        frog = try values.decodeIfPresent(String.self, forKey: .frog)
        permissions = try values.decodeIfPresent([String].self, forKey: .permissions) ?? []
        manifest = try values.decode(String.self, forKey: .manifest)
        download = try values.decode(String.self, forKey: .download)
        sha256 = try values.decode(String.self, forKey: .sha256)
        signature = try values.decodeIfPresent(String.self, forKey: .signature) ?? ""
    }

    public var downloadURL: URL? { Self.https(download) }
    public var manifestURL: URL? { Self.https(manifest) }
    public var displaySymbol: String { symbol ?? PluginManifest.defaultSymbol }

    /// The exact bytes the signature covers: a header line, then one `key: value` line per field in a fixed order.
    /// The website's signing script writes the same bytes; a field that is absent is an empty value.
    public var signedMessage: Data {
        let fields: [(String, String)] = [
            ("id", id), ("name", name), ("summary", summary), ("version", version), ("author", author),
            ("symbol", symbol ?? ""), ("homepage", homepage ?? ""), ("frog", frog ?? ""),
            ("permissions", permissions.joined(separator: ",")), ("manifest", manifest), ("download", download),
            ("sha256", sha256.lowercased()),
        ]
        let lines = [PluginRegistry.messageHeader] + fields.map { "\($0.0): \($0.1)" }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Whether the entry is well formed, apart from its signature.
    public func check() throws {
        guard PluginManifest.isValidID(id) else { throw PluginError.invalid("The id “\(id)” is not a plugin id.") }
        guard PluginVersion(version) != nil else { throw PluginError.invalid("The version “\(version)” must look like 1.0.0.") }
        for (field, value, maximum) in [("name", name, 40), ("summary", summary, 200), ("author", author, 60)] {
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty, value.count <= maximum else {
                throw PluginError.invalid("The \(field) must be 1 to \(maximum) characters.")
            }
        }
        let all = [id, name, summary, version, author, symbol ?? "", homepage ?? "", frog ?? "", manifest, download, sha256] + permissions
        guard !all.contains(where: { $0.contains(where: \.isNewline) }) else { throw PluginError.invalid("Every field must be one line.") }
        guard !permissions.contains(where: { $0.contains(",") }) else { throw PluginError.invalid("A permission has a comma.") }
        guard downloadURL != nil, manifestURL != nil else { throw PluginError.invalid("The manifest and download must be https links.") }
        if let homepage, Self.https(homepage) == nil { throw PluginError.invalid("The homepage must be an https link.") }
        if let frog, PluginVersion(frog) == nil { throw PluginError.invalid("“frog” must be a Frog version, such as 1.0.40.") }
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { throw PluginError.invalid("The sha256 must be 64 hex digits.") }
    }

    /// Whether one of `keys` (base64 raw Ed25519 public keys) signed this entry.
    public func isSigned(byOneOf keys: [String]) -> Bool {
        guard let signature = Data(base64Encoded: signature), signature.count == 64 else { return false }
        let message = signedMessage
        return keys.contains { key in
            guard let raw = Data(base64Encoded: key), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return publicKey.isValidSignature(signature, for: message)
        }
    }

    /// Whether the plugin works with this Frog version; a development build always does.
    public func runs(on frogVersion: String) -> Bool {
        guard let frog, let needed = PluginVersion(frog), let current = PluginVersion(frogVersion) else { return true }
        return current >= needed
    }

    /// Whether the entry matches `query` by name, summary, author, id or permission.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = ([id, name, summary, author] + permissions).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    private static func https(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// The directory's `registry.json`: `{ "format": 1, "plugins": [...] }`.
public struct PluginRegistry: Codable, Equatable, Sendable {
    public static let messageHeader = "frog-plugin-registry-entry-v1"
    /// The public halves of the keys that sign the directory at frog.beffa.xyz, as base64 raw Ed25519 keys. The
    /// private key never leaves its owner's Keychain, and signs entries when the website is built. Empty until the
    /// first key is made, and until then nothing in the directory installs.
    public static let trustedKeys: [String] = []

    public var format: Int
    public var plugins: [PluginRegistryEntry]

    public init(format: Int = 1, plugins: [PluginRegistryEntry] = []) {
        self.format = format; self.plugins = plugins
    }

    /// The entries of `data` that are well formed and signed by one of `keys`, newest version per id, and how many
    /// were left out.
    public static func verified(_ data: Data, keys: [String] = trustedKeys) throws -> (entries: [PluginRegistryEntry], rejected: Int) {
        let registry: PluginRegistry
        do { registry = try JSONDecoder().decode(PluginRegistry.self, from: data) }
        catch { throw PluginError.invalid("registry.json is not a plugin registry.") }
        guard registry.format == 1 else { throw PluginError.invalid("registry.json has format \(registry.format); update Frog to read it.") }
        var newest: [String: PluginRegistryEntry] = [:]
        var rejected = 0
        for entry in registry.plugins {
            guard (try? entry.check()) != nil, entry.isSigned(byOneOf: keys) else { rejected += 1; continue }
            if let current = newest[entry.id], let a = PluginVersion(current.version), let b = PluginVersion(entry.version), a >= b { continue }
            newest[entry.id] = entry
        }
        let entries = newest.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (entries, rejected)
    }
}
