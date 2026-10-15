import Foundation
import FrogCore
import Security

/// Reads the team ID and app groups an app or a single executable is signed with. It only names
/// identifiers, so the signature is not validated.
struct SecurityCodeSignatureReader: CodeSignatureReading {
    private static let appGroupsKey = "com.apple.security.application-groups"
    private static let maximumGroups = 32
    private static let maximumGroupLength = 128

    func signature(of bundle: URL) -> CodeSignatureInfo? {
        // An app in iCloud Drive may be a placeholder; reading it must not download it.
        CleanerIOPolicy.withoutDownloading {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let information = information as? [String: Any] else { return nil }
            // An unsigned bundle has no identifier; there is nothing to name.
            guard information[kSecCodeInfoIdentifier as String] != nil else { return nil }
            let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            return CodeSignatureInfo(teamID: information[kSecCodeInfoTeamIdentifier as String] as? String,
                                     appGroups: Self.appGroups(entitlements?[Self.appGroupsKey]))
        }
    }

    /// At most 32 strings of at most 128 characters; anything else in the entitlement is ignored.
    static func appGroups(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        let groups = values.compactMap { $0 as? String }.filter { !$0.isEmpty && $0.count <= maximumGroupLength }
        return Array(groups.prefix(maximumGroups))
    }
}
