import Foundation
import Darwin

/// What the cleaner knows about one installed app: the names and bundle IDs its leftovers are matched by.
public struct AppIdentity: Codable, Hashable, Sendable, Identifiable {
    /// "/Applications/Slack.app"
    public var path: String
    /// The name Finder shows, without ".app".
    public var name: String
    public var bundleID: String
    /// CFBundleName
    public var bundleName: String?
    /// CFBundleDisplayName
    public var displayName: String?
    /// CFBundleExecutable
    public var executableName: String?
    /// CFBundleShortVersionString, else CFBundleVersion.
    public var version: String?
    public var teamID: String?
    /// The app's and its nested bundles' app groups, distinct, in the order found.
    public var appGroups: [String]
    public var nestedBundleIDs: [String]
    /// `Contents/_MASReceipt` exists.
    public var isAppStore: Bool
    /// `Contents/Library/SystemExtensions` has an entry.
    public var hasSystemExtensions: Bool
    /// `Contents/Library/LoginItems` or `Contents/Library/LaunchAgents` has an entry.
    public var hasLoginItems: Bool
    /// The path of the vendor's own uninstaller app.
    public var vendorUninstaller: String?
    /// `.administrator` when the bundle is not owned by the current user.
    public var owner: CleanerOwner

    public init(path: String, name: String, bundleID: String, bundleName: String? = nil, displayName: String? = nil,
                executableName: String? = nil, version: String? = nil, teamID: String? = nil, appGroups: [String] = [],
                nestedBundleIDs: [String] = [], isAppStore: Bool = false, hasSystemExtensions: Bool = false,
                hasLoginItems: Bool = false, vendorUninstaller: String? = nil, owner: CleanerOwner = .user) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.bundleName = bundleName
        self.displayName = displayName
        self.executableName = executableName
        self.version = version
        self.teamID = teamID
        self.appGroups = appGroups
        self.nestedBundleIDs = nestedBundleIDs
        self.isAppStore = isAppStore
        self.hasSystemExtensions = hasSystemExtensions
        self.hasLoginItems = hasLoginItems
        self.vendorUninstaller = vendorUninstaller
        self.owner = owner
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var bundleIDs: [String] { [bundleID] + nestedBundleIDs }
    public var isAppleApp: Bool { bundleID.hasPrefix("com.apple.") }

    /// Distinct names for exact-name matching: file name, CFBundleName, CFBundleDisplayName,
    /// CFBundleExecutable; a trailing space plus version ("Foo 2", "Foo 2024") removed; compared
    /// case-insensitively; empty names dropped.
    public var names: [String] {
        var seen = Set<String>()
        return [name, bundleName, displayName, executableName].compactMap { $0 }.compactMap { candidate in
            var trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if let version = trimmed.range(of: #" +v?[0-9][0-9.]*$"#, options: .regularExpression),
               version.lowerBound > trimmed.startIndex {
                trimmed = String(trimmed[..<version.lowerBound])
            }
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}

/// What a code signature tells the cleaner.
public struct CodeSignatureInfo: Sendable, Equatable {
    public var teamID: String?
    /// The `com.apple.security.application-groups` entitlement.
    public var appGroups: [String]
    public init(teamID: String? = nil, appGroups: [String] = []) {
        self.teamID = teamID
        self.appGroups = appGroups
    }
}

/// `bundle` is a bundle folder or a single Mach-O file; `SecStaticCodeCreateWithPath` accepts both.
public protocol CodeSignatureReading: Sendable { func signature(of bundle: URL) -> CodeSignatureInfo? }

/// Reads no signatures: identities without team IDs and app groups.
public struct NoCodeSignatures: CodeSignatureReading {
    public init() {}
    public func signature(of bundle: URL) -> CodeSignatureInfo? { nil }
}

/// Builds an `AppIdentity` from an app bundle. It reads only Info.plist files and the names of folders
/// inside the bundle, never other file contents.
public struct AppBundleInspector: Sendable {
    private let signatures: any CodeSignatureReading
    private let owner: @Sendable (URL) -> CleanerOwner

    private static let nestedExtensions: Set<String> = ["app", "appex", "xpc", "systemextension"]
    private static let maximumNestedBundles = 64
    private static let maximumSignedNestedBundles = 16

    public init(signatures: any CodeSignatureReading = NoCodeSignatures(),
                owner: @escaping @Sendable (URL) -> CleanerOwner = AppBundleInspector.fileOwner) {
        self.signatures = signatures
        self.owner = owner
    }

    /// `.user` when the current user owns the item; unreadable items count as the administrator's,
    /// so they go through Finder.
    public static let fileOwner: @Sendable (URL) -> CleanerOwner = { url in
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .administrator }
        return info.st_uid == getuid() ? .user : .administrator
    }

    /// Throws when the folder has no readable Info.plist or no bundle ID.
    public func identity(of bundle: URL, displayName: String? = nil) throws -> AppIdentity {
        let bundle = bundle.standardizedFileURL
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard let info = Self.infoDictionary(contents),
              let bundleID = Self.string(info["CFBundleIdentifier"]) else {
            throw FrogError.message("Frog cannot read this app.")
        }
        let shown = displayName ?? bundle.lastPathComponent
        let name = shown.lowercased().hasSuffix(".app") ? String(shown.dropLast(4)) : shown

        var nestedIDs: [String] = []
        var nestedBundles: [URL] = []
        var seen: Set<String> = [bundleID.lowercased()]
        for nested in Self.nestedBundles(in: contents) where nestedIDs.count < Self.maximumNestedBundles {
            guard let id = Self.infoDictionary(nested.appendingPathComponent("Contents", isDirectory: true))
                .flatMap({ Self.string($0["CFBundleIdentifier"]) }),
                  !CleanerSafety.isAppleName(id), !id.lowercased().hasPrefix("org.sparkle-project."),
                  seen.insert(id.lowercased()).inserted else { continue }
            nestedIDs.append(id)
            nestedBundles.append(nested)
        }

        let signature = signatures.signature(of: bundle)
        // Extensions often declare groups the main app does not.
        var groups: [String] = []
        let nestedGroups = nestedBundles.prefix(Self.maximumSignedNestedBundles)
            .flatMap { signatures.signature(of: $0)?.appGroups ?? [] }
        for group in (signature?.appGroups ?? []) + nestedGroups where !groups.contains(group) { groups.append(group) }

        var identity = AppIdentity(
            path: bundle.path, name: name, bundleID: bundleID,
            bundleName: Self.string(info["CFBundleName"]), displayName: Self.string(info["CFBundleDisplayName"]),
            executableName: Self.string(info["CFBundleExecutable"]),
            version: Self.string(info["CFBundleShortVersionString"]) ?? Self.string(info["CFBundleVersion"]),
            teamID: signature?.teamID, appGroups: groups, nestedBundleIDs: nestedIDs,
            isAppStore: Self.exists(contents.appendingPathComponent("_MASReceipt")),
            hasSystemExtensions: Self.hasEntries(contents.appendingPathComponent("Library/SystemExtensions")),
            hasLoginItems: Self.hasEntries(contents.appendingPathComponent("Library/LoginItems"))
                || Self.hasEntries(contents.appendingPathComponent("Library/LaunchAgents")),
            owner: owner(bundle))
        identity.vendorUninstaller = Self.vendorUninstaller(for: bundle, names: identity.names)
        return identity
    }

    private static func infoDictionary(_ contents: URL) -> [String: Any]? {
        guard let data = try? PrivateFile.read(contents.appendingPathComponent("Info.plist"), maximumBytes: 1_048_576)
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Bundles up to four levels inside `Contents`, without following links. Inside `Contents/Frameworks` only
    /// the apps directly in it count (Electron and Chromium helpers); frameworks hold copies Frog must not claim.
    private static func nestedBundles(in contents: URL) -> [URL] {
        var found: [URL] = []
        func walk(_ folder: URL, level: Int) {
            for child in folders(in: folder) {
                if level == 1, child.lastPathComponent == "Frameworks" {
                    found += folders(in: child).filter { $0.pathExtension.lowercased() == "app" }
                    continue
                }
                if nestedExtensions.contains(child.pathExtension.lowercased()) { found.append(child) }
                if level < 4 { walk(child, level: level + 1) }
            }
        }
        walk(contents, level: 1)
        return found
    }

    /// The real folders directly inside `folder`, sorted by name; links are skipped.
    private static func folders(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            let child = folder.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(child.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return child
        }
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func hasEntries(_ folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { !$0.hasPrefix(".") }
    }

    /// A sibling or `Contents/Resources` app whose name says "Uninstall" and names the app, for example
    /// `/Applications/Adobe Foo/Uninstall Adobe Foo.app`.
    private static func vendorUninstaller(for bundle: URL, names: [String]) -> String? {
        // A very short name such as "Go" would match unrelated uninstallers.
        let names = names.map { $0.lowercased() }.filter { $0.count >= 3 }
        let candidates = folders(in: bundle.deletingLastPathComponent())
            + folders(in: bundle.appendingPathComponent("Contents/Resources", isDirectory: true))
        return candidates.first { candidate in
            guard candidate.pathExtension.lowercased() == "app", candidate.path != bundle.path else { return false }
            let name = candidate.deletingPathExtension().lastPathComponent.lowercased()
            return name.contains("uninstall") && names.contains { name.contains($0) }
        }?.path
    }
}
