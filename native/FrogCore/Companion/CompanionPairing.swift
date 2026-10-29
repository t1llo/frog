import Foundation
import Security

/// Where phone pairing secrets live: the login Keychain in the app, memory in tests.
public protocol PhoneSecretStore: Sendable {
    func read(phoneID: UUID) throws -> Data?
    func save(_ secret: Data, phoneID: UUID) throws
    func delete(phoneID: UUID) throws
}

/// One generic password per phone; never synced, readable after first unlock.
public final class KeychainPhoneSecretStore: PhoneSecretStore, Sendable {
    private let service = "com.frog.phone-pairing"
    public init() {}

    public func read(phoneID: UUID) throws -> Data? {
        var query = identity(phoneID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStore.failure(status) }
        return result as? Data
    }

    public func save(_ secret: Data, phoneID: UUID) throws {
        let query = identity(phoneID)
        let attributes: [String: Any] = [kSecValueData as String: secret]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = secret
            item[kSecAttrLabel as String] = "Frog phone pairing"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw KeychainStore.failure(status) }
    }

    public func delete(phoneID: UUID) throws {
        let status = SecItemDelete(identity(phoneID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStore.failure(status) }
    }

    private func identity(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.companionString,
         kSecAttrSynchronizable as String: false]
    }
}

public final class InMemoryPhoneSecretStore: PhoneSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: Data] = [:]
    public init() {}
    public func read(phoneID: UUID) throws -> Data? { lock.withLock { secrets[phoneID] } }
    public func save(_ secret: Data, phoneID: UUID) throws { lock.withLock { secrets[phoneID] = secret } }
    public func delete(phoneID: UUID) throws { _ = lock.withLock { secrets.removeValue(forKey: phoneID) } }
}

public struct PairedPhone: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var pairedAt: Date

    public init(id: UUID, name: String, pairedAt: Date) {
        self.id = id; self.name = name; self.pairedAt = pairedAt
    }
}

/// Paired phones and this Mac's companion device ID. Names and IDs live in a private file in Frog's
/// data directory; secrets live in the `PhoneSecretStore`. Neither is part of a configuration export.
@MainActor
public final class PhonePairingStore {
    private struct Stored: Codable {
        var macID: UUID
        var phones: [PairedPhone]
    }

    public let fileURL: URL
    private let secrets: any PhoneSecretStore
    private var secretCache: [UUID: Data] = [:]
    public private(set) var macID: UUID
    public private(set) var phones: [PairedPhone]

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func defaultFile(in directory: URL) -> URL {
        directory.appendingPathComponent("phone.json")
    }

    public init(fileURL: URL, secrets: any PhoneSecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
        let stored = (try? PrivateFile.read(fileURL, maximumBytes: 1_048_576))
            .flatMap { $0 }
            .flatMap { try? Self.decoder.decode(Stored.self, from: $0) }
        if let stored {
            macID = stored.macID
            phones = stored.phones
        } else {
            macID = UUID()
            phones = []
        }
    }

    public func phone(_ id: UUID) -> PairedPhone? { phones.first { $0.id == id } }

    public func secret(for id: UUID) -> Data? {
        guard phone(id) != nil else { return nil }
        if let cached = secretCache[id] { return cached }
        let secret = try? secrets.read(phoneID: id)
        secretCache[id] = secret
        return secret
    }

    /// Stores a newly paired phone; a known ID gets its new name and secret.
    public func save(id: UUID, name: String, secret: Data, at date: Date = Date()) throws {
        try secrets.save(secret, phoneID: id)
        secretCache[id] = secret
        if let index = phones.firstIndex(where: { $0.id == id }) {
            phones[index].name = name
        } else {
            phones.append(PairedPhone(id: id, name: name, pairedAt: date))
        }
        try persist()
    }

    public func rename(_ id: UUID, to name: String) {
        guard !name.isEmpty, let index = phones.firstIndex(where: { $0.id == id }), phones[index].name != name else { return }
        phones[index].name = name
        try? persist()
    }

    public func remove(_ id: UUID) throws {
        try? secrets.delete(phoneID: id)
        secretCache[id] = nil
        phones.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try PrivateFile.write(try encoder.encode(Stored(macID: macID, phones: phones)), to: fileURL)
    }
}

/// Saves received files into a folder (Downloads in the app), never overwriting.
public enum CompanionFileSaver {
    public static func save(_ data: Data, suggestedName: String?, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(for: sanitized(suggestedName), in: folder)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// A safe single file name: no separators, no leading dots, at most about 150 characters.
    public static func sanitized(_ name: String?) -> String {
        var cleaned = (name ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "Phone file" }
        if cleaned.utf8.count > 200 { cleaned = String(cleaned.prefix(150)) }
        return cleaned
    }

    /// "photo.jpg", then "photo 2.jpg", "photo 3.jpg", like Finder.
    public static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        repeat {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

/// One item sent to or received from a phone, kept in memory for the Phone page.
public struct PhoneRecentItem: Identifiable, Equatable, Sendable {
    public enum Direction: String, Sendable { case sent, received }

    public enum Status: String, Sendable {
        /// Sent; no phone acknowledged it yet.
        case sending
        /// A phone acknowledged it.
        case delivered
        /// Too large for Bluetooth; goes out when a phone connects over Wi-Fi.
        case waitingForWiFi
        /// No phone was connected, or it gave up.
        case notDelivered
        case received
    }

    public let id: String
    public let direction: Direction
    public let kind: CompanionClipKind
    /// One line: the text, the file name, or "Image".
    public let title: String
    public let peerName: String
    public let date: Date
    public var status: Status
    /// A received file in Downloads, or the file that was sent.
    public var fileURL: URL?
    public let size: Int

    public init(id: String, direction: Direction, kind: CompanionClipKind, title: String, peerName: String,
                date: Date, status: Status, fileURL: URL? = nil, size: Int) {
        self.id = id; self.direction = direction; self.kind = kind; self.title = title; self.peerName = peerName
        self.date = date; self.status = status; self.fileURL = fileURL; self.size = size
    }

    /// A one-line title for a clip.
    public static func title(kind: CompanionClipKind, name: String?, text: String?) -> String {
        switch kind {
        case .text:
            let line = (text ?? "").prefix(300).split(whereSeparator: \.isNewline).first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return line.isEmpty ? "Text" : line
        case .image: return name ?? "Image"
        case .file: return name ?? "File"
        }
    }
}
