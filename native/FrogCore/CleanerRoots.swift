import Foundation
import Darwin

/// The current user's Library (`~/Library`) or the shared one (`/Library`).
public enum CleanerDomain: String, Codable, Sendable { case user, system }

/// Where apps keep data, relative to a Library folder. The raw values are also the location names
/// the AI assist may use, so do not rename them.
public enum LeftoverLocation: String, CaseIterable, Codable, Sendable {
    case applicationSupport, caches, preferences, byHostPreferences, containers, groupContainers,
         savedState, logs, diagnosticReports, httpStorages, webKit, cookies, applicationScripts,
         launchAgents, launchDaemons, privilegedHelperTools

    public var relativePath: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .byHostPreferences: "Preferences/ByHost"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .savedState: "Saved Application State"
        case .logs: "Logs"
        case .diagnosticReports: "Logs/DiagnosticReports"
        case .httpStorages: "HTTPStorages"
        case .webKit: "WebKit"
        case .cookies: "Cookies"
        case .applicationScripts: "Application Scripts"
        case .launchAgents: "LaunchAgents"
        case .launchDaemons: "LaunchDaemons"
        case .privilegedHelperTools: "PrivilegedHelperTools"
        }
    }

    /// The Library folders that have this location.
    public var domains: [CleanerDomain] {
        switch self {
        case .applicationSupport, .caches, .preferences, .logs, .launchAgents: [.user, .system]
        case .launchDaemons, .privilegedHelperTools: [.system]
        default: [.user]
        }
    }

    /// Never listed: Frog probes exact names with lstat, so it does not read other apps' data.
    public var probesOnly: Bool { self == .containers || self == .groupContainers }

    /// macOS asks for Full Disk Access before anything inside can be read reliably.
    public var needsFullDiskAccess: Bool { self == .containers || self == .groupContainers || self == .cookies }

    /// The kind of a folder found here; a plain file found in a `folder` location becomes `.file`.
    public var itemKind: CleanerItemKind {
        switch self {
        case .preferences, .byHostPreferences: .preferences
        case .containers: .container
        case .groupContainers: .groupContainer
        case .launchAgents: .launchAgent
        case .launchDaemons: .launchDaemon
        case .privilegedHelperTools: .helperTool
        default: .folder
        }
    }
}

/// The two folder trees the cleaner works in: the home folder and the system root (`/` in the app, a fixture
/// folder in tests). Both are resolved once with realpath(3), so `/var/...` and `/private/var/...` compare equal.
public struct CleanerRoots: Sendable, Equatable {
    public var home: URL
    public var system: URL
    /// The spellings the roots were given in, longest first, for `resolved(_:)`.
    private var aliases: [Alias]

    private struct Alias: Sendable, Equatable {
        var given: String
        var resolved: String
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                system: URL = URL(fileURLWithPath: "/", isDirectory: true)) {
        var aliases: [Alias] = []
        func resolve(_ url: URL) -> URL {
            let given = url.standardizedFileURL.path
            guard let pointer = realpath(given, nil) else { return URL(fileURLWithPath: given, isDirectory: true) }
            defer { free(pointer) }
            let resolved = String(cString: pointer)
            if given != resolved, given != "/" { aliases.append(Alias(given: given, resolved: resolved)) }
            return URL(fileURLWithPath: resolved, isDirectory: true)
        }
        self.home = resolve(home)
        self.system = resolve(system)
        self.aliases = aliases.sorted { $0.given.count > $1.given.count }
    }

    /// Rewrites a path given in the unresolved spelling of a root (for example `/var/folders/...` for a
    /// root that resolved to `/private/var/folders/...`) to the resolved spelling; other paths unchanged.
    public func resolved(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for alias in aliases {
            if path == alias.given { return URL(fileURLWithPath: alias.resolved, isDirectory: true) }
            if path.hasPrefix(alias.given + "/") {
                return URL(fileURLWithPath: alias.resolved + path.dropFirst(alias.given.count))
            }
        }
        return URL(fileURLWithPath: path)
    }

    public var userLibrary: URL { home.appendingPathComponent("Library", isDirectory: true) }
    public var systemLibrary: URL { system.appendingPathComponent("Library", isDirectory: true) }
    /// Where installed apps live: `/Applications` and `~/Applications`.
    public var applicationFolders: [URL] {
        [system.appendingPathComponent("Applications", isDirectory: true),
         home.appendingPathComponent("Applications", isDirectory: true)]
    }

    public func library(_ domain: CleanerDomain) -> URL { domain == .user ? userLibrary : systemLibrary }

    /// nil when the location does not exist in that domain.
    public func folder(_ location: LeftoverLocation, _ domain: CleanerDomain) -> URL? {
        guard location.domains.contains(domain) else { return nil }
        return library(domain).appendingPathComponent(location.relativePath, isDirectory: true)
    }

    /// "~/Library/Caches/com.example" for paths in home; the full path otherwise.
    public func displayPath(_ url: URL) -> String {
        let path = resolved(url).path
        if path == home.path { return "~" }
        if let relative = Self.relative(path, below: home.path) { return "~/" + relative }
        return path
    }

    /// The part of `path` below `root`, or nil when `path` is not strictly inside it.
    static func relative(_ path: String, below root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    static func isInside(_ path: String, _ root: String, orEqual: Bool) -> Bool {
        (orEqual && path == root) || relative(path, below: root) != nil
    }
}
