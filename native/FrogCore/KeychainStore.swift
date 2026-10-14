import Foundation
import Security

public final class KeychainStore: Sendable {
    private let service = "com.frog.provider-credentials"
    public init() {}

    public func read(providerID: UUID) throws -> String? {
        var query = identity(providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw FrogError.message("The saved API key could not be read. Replace it in Providers.")
        }
        return key
    }

    public func save(_ key: String, providerID: UUID) throws {
        let key = try Self.validatedKey(key)
        let query = identity(providerID)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            status = SecItemAdd(item as CFDictionary, nil)
            // A concurrent save may have created it between update and add.
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        }
        try check(status)
    }

    public func delete(providerID: UUID) throws {
        let status = SecItemDelete(identity(providerID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    static func validatedKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8_192,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw FrogError.message("Enter a nonempty API key without spaces or control characters.")
        }
        return trimmed
    }

    private func identity(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    /// Why a Keychain call failed, as far as the person using Frog can act on it.
    enum Failure: Equatable {
        case locked, cancelled, denied, unavailable, other(OSStatus)
        init(_ status: OSStatus) {
            switch status {
            case errSecInteractionNotAllowed: self = .locked
            case errSecUserCanceled: self = .cancelled
            case errSecAuthFailed: self = .denied
            case errSecNoSuchKeychain, errSecNoDefaultKeychain, errSecNotAvailable: self = .unavailable
            default: self = .other(status)
            }
        }
    }

    /// No raw Keychain item or credential appears in diagnostics.
    static func failure(_ status: OSStatus) -> FrogError {
        switch Failure(status) {
        case .locked: .message("Your login keychain is locked. Unlock it and try again.")
        case .cancelled: .message("Keychain access was cancelled. Try again and allow Frog when macOS asks.")
        case .denied: .message("macOS did not allow Frog to use the Keychain. Try again, and allow Frog when macOS asks.")
        case .unavailable: .message("No login keychain is available. Check it in Keychain Access, then try again.")
        case .other(let status): .message("Keychain access failed (\(status)). Try again; if it keeps failing, check your login keychain in Keychain Access.")
        }
    }
}
