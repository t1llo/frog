import Foundation

/// Something a plugin may do beyond showing its page, keeping its own storage and receiving its commands.
/// The user approves each one; `docs/plugins.md` describes them for plugin authors.
public enum PluginPermission: String, Codable, CaseIterable, Comparable, Sendable {
    case clipboardRead = "clipboard-read"
    case clipboardWrite = "clipboard-write"
    case notifications
    case links
    case network
    case ai
    case scripts

    public var title: String {
        switch self {
        case .clipboardRead: "Read the clipboard"
        case .clipboardWrite: "Put text on the clipboard"
        case .notifications: "Show notifications"
        case .links: "Open web links in your browser"
        case .network: "Connect to the internet"
        case .ai: "Use your AI model"
        case .scripts: "Run shell scripts on this Mac"
        }
    }

    /// What granting it means, for the review sheet.
    public var detail: String {
        switch self {
        case .clipboardRead: "Reads the text you copied. Text a password manager marks as concealed is never given."
        case .clipboardWrite: "Replaces what is on the clipboard with text of its own."
        case .notifications: "Shows notifications from Frog."
        case .links: "Opens https links in your default browser, which can send what is in the link to that site."
        case .network: "Sends requests to the sites listed below, and only those. It can send them anything the plugin can read."
        case .ai: "Sends text to the model your Writing rules use by default. A cloud model's provider bills you for it."
        case .scripts: "Runs the scripts shown below with your full access to this Mac: your files, apps and accounts. Install it only if you trust the author and have read the scripts."
        }
    }

    /// Permissions that can send data off the Mac or act beyond the sandbox, shown with a caution.
    public var isSensitive: Bool { [.clipboardRead, .network, .ai, .scripts].contains(self) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A command bar row a plugin adds. Choosing it sends `id` to the plugin's page.
public struct PluginCommand: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var keywords: String?
    /// False runs the command without bringing the page forward.
    public var show: Bool?
    public var opensPage: Bool { show ?? true }

    public init(id: String, title: String, keywords: String? = nil, show: Bool? = nil) {
        self.id = id; self.title = title; self.keywords = keywords; self.show = show
    }
}

/// A plugin's `plugin.json`.
public struct PluginManifest: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var author: String?
    public var homepage: String?
    public var symbol: String?
    /// The page Frog opens, relative to the plugin's folder; nil for a plugin with commands only.
    public var entry: String?
    /// The oldest Frog version the plugin works with.
    public var frog: String?
    public var permissions: [PluginPermission]
    public var hosts: [String]
    /// Script names mapped to paths inside the plugin's folder.
    public var scripts: [String: String]
    public var commands: [PluginCommand]

    public static let fileName = "plugin.json"
    public static let defaultSymbol = "puzzlepiece.extension"
    public var displaySymbol: String { symbol ?? Self.defaultSymbol }

    public init(id: String, name: String, version: String = "1.0.0", description: String, author: String? = nil, homepage: String? = nil,
                symbol: String? = nil, entry: String? = "index.html", frog: String? = nil, permissions: [PluginPermission] = [],
                hosts: [String] = [], scripts: [String: String] = [:], commands: [PluginCommand] = []) {
        self.id = id; self.name = name; self.version = version; self.description = description; self.author = author
        self.homepage = homepage; self.symbol = symbol; self.entry = entry; self.frog = frog; self.permissions = permissions
        self.hosts = hosts; self.scripts = scripts; self.commands = commands
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, homepage, symbol, entry, frog, permissions, hosts, scripts, commands
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        description = try values.decode(String.self, forKey: .description)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        homepage = try values.decodeIfPresent(String.self, forKey: .homepage)
        symbol = try values.decodeIfPresent(String.self, forKey: .symbol)
        // A missing entry means index.html; an explicit null means the plugin has no page.
        if values.contains(.entry) { entry = try values.decodeNil(forKey: .entry) ? nil : try values.decode(String.self, forKey: .entry) }
        else { entry = "index.html" }
        frog = try values.decodeIfPresent(String.self, forKey: .frog)
        let names = try values.decodeIfPresent([String].self, forKey: .permissions) ?? []
        permissions = try names.map { name in
            guard let permission = PluginPermission(rawValue: name) else {
                throw PluginError.invalid("Unknown permission “\(name)”. Use \(PluginPermission.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return permission
        }
        hosts = try values.decodeIfPresent([String].self, forKey: .hosts) ?? []
        scripts = try values.decodeIfPresent([String: String].self, forKey: .scripts) ?? [:]
        commands = try values.decodeIfPresent([PluginCommand].self, forKey: .commands) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(version, forKey: .version)
        try values.encode(description, forKey: .description)
        try values.encodeIfPresent(author, forKey: .author)
        try values.encodeIfPresent(homepage, forKey: .homepage)
        try values.encodeIfPresent(symbol, forKey: .symbol)
        if let entry { try values.encode(entry, forKey: .entry) } else { try values.encodeNil(forKey: .entry) }
        try values.encodeIfPresent(frog, forKey: .frog)
        if !permissions.isEmpty { try values.encode(permissions, forKey: .permissions) }
        if !hosts.isEmpty { try values.encode(hosts, forKey: .hosts) }
        if !scripts.isEmpty { try values.encode(scripts, forKey: .scripts) }
        if !commands.isEmpty { try values.encode(commands, forKey: .commands) }
    }

    /// Reads and checks a manifest's JSON.
    public static func decode(_ data: Data) throws -> PluginManifest {
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) }
        catch let error as PluginError { throw error }
        catch DecodingError.keyNotFound(let key, _) { throw PluginError.invalid("plugin.json needs “\(key.stringValue)”.") }
        catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw PluginError.invalid("plugin.json has the wrong kind of value at “\(path)”.")
        }
        catch { throw PluginError.invalid("plugin.json is not valid JSON.") }
        try manifest.validate()
        return manifest
    }

    /// Checks everything that does not need the plugin's files.
    public func validate() throws {
        guard Self.isValidID(id) else {
            throw PluginError.invalid("The id “\(id)” must be 3 to 64 lowercase letters, digits, dots and hyphens, such as com.example.word-counter.")
        }
        try Self.check(name, "name", maximum: 40)
        guard PluginVersion(version) != nil else { throw PluginError.invalid("The version “\(version)” must look like 1.0.0.") }
        try Self.check(description, "description", maximum: 200)
        if let author { try Self.check(author, "author", maximum: 60) }
        if let homepage {
            guard let url = URL(string: homepage), url.scheme == "https", url.host?.isEmpty == false else {
                throw PluginError.invalid("The homepage must be an https link.")
            }
        }
        if let symbol, symbol.isEmpty || symbol.count > 60 || !symbol.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) {
            throw PluginError.invalid("The symbol “\(symbol)” must be an SF Symbol name, such as textformat.123.")
        }
        if let entry {
            guard PluginPath.isSafe(entry), entry.lowercased().hasSuffix(".html") || entry.lowercased().hasSuffix(".htm") else {
                throw PluginError.invalid("The entry “\(entry)” must be an .html file inside the plugin's folder.")
            }
        }
        if let frog, PluginVersion(frog) == nil { throw PluginError.invalid("“frog” must be a Frog version, such as 1.0.40.") }
        guard Set(permissions).count == permissions.count else { throw PluginError.invalid("A permission is listed twice.") }

        let wantsNetwork = permissions.contains(.network)
        if wantsNetwork, hosts.isEmpty { throw PluginError.invalid("The network permission needs the hosts it reaches, in “hosts”.") }
        if !wantsNetwork, !hosts.isEmpty { throw PluginError.invalid("“hosts” needs the network permission.") }
        guard hosts.count <= 20 else { throw PluginError.invalid("A plugin can name at most 20 hosts.") }
        for host in hosts where PluginHost(host) == nil {
            throw PluginError.invalid("The host “\(host)” must be a lowercase host name such as api.github.com or *.example.com, with no scheme or path.")
        }

        let wantsScripts = permissions.contains(.scripts)
        if wantsScripts, scripts.isEmpty { throw PluginError.invalid("The scripts permission needs the scripts it runs, in “scripts”.") }
        if !wantsScripts, !scripts.isEmpty { throw PluginError.invalid("“scripts” needs the scripts permission.") }
        guard scripts.count <= 20 else { throw PluginError.invalid("A plugin can have at most 20 scripts.") }
        for (name, path) in scripts {
            guard Self.isValidName(name) else { throw PluginError.invalid("The script name “\(name)” must be lowercase letters, digits and hyphens.") }
            guard PluginPath.isSafe(path) else { throw PluginError.invalid("The script “\(name)” must be a file inside the plugin's folder.") }
        }

        guard commands.count <= 20 else { throw PluginError.invalid("A plugin can have at most 20 commands.") }
        guard Set(commands.map(\.id)).count == commands.count else { throw PluginError.invalid("Two commands have the same id.") }
        for command in commands {
            guard Self.isValidName(command.id) else { throw PluginError.invalid("The command id “\(command.id)” must be lowercase letters, digits and hyphens.") }
            try Self.check(command.title, "command title", maximum: 60)
            if let keywords = command.keywords, keywords.count > 120 { throw PluginError.invalid("A command's keywords must be at most 120 characters.") }
        }
        if entry == nil {
            guard !commands.isEmpty else { throw PluginError.invalid("A plugin needs a page (“entry”) or commands.") }
        }
    }

    /// The access the plugin asks for, given the SHA-256 of each of its scripts.
    public func grant(scriptHashes: [String: String]) -> PluginGrant {
        PluginGrant(permissions: permissions, hosts: hosts, scripts: scripts.keys.reduce(into: [:]) { $0[$1] = scriptHashes[$1] ?? "" })
    }

    /// Whether this Frog version is new enough, for a version such as "1.0.40"; a development build always is.
    public func runs(on frogVersion: String) -> Bool {
        guard let frog, let needed = PluginVersion(frog), let current = PluginVersion(frogVersion) else { return true }
        return current >= needed
    }

    static func isValidID(_ id: String) -> Bool {
        guard (3...64).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }) else { return false }
        // Every dot-separated part is a host name label: it neither starts nor ends with a hyphen.
        return id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-"
        }
    }

    static func isValidName(_ name: String) -> Bool {
        (1...32).contains(name.count) && name.first != "-" && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    private static func check(_ text: String, _ field: String, maximum: Int) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PluginError.invalid("The \(field) is empty.") }
        guard text.count <= maximum else { throw PluginError.invalid("The \(field) must be at most \(maximum) characters.") }
        guard !text.contains(where: { $0.isNewline }) else { throw PluginError.invalid("The \(field) must be one line.") }
    }
}

/// A version such as 1.2.3.
public struct PluginVersion: Comparable, Sendable {
    public let parts: [Int]
    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let numbers = pieces.compactMap { piece -> Int? in
            guard (1...6).contains(piece.count), piece.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(piece)
        }
        guard numbers.count == 3 else { return nil }
        parts = numbers
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

/// A host a plugin may reach with `frog.fetch`: an exact name, or `*.` and a domain for its subdomains.
/// Plain http is allowed only for this Mac.
public struct PluginHost: Equatable, Sendable {
    public let pattern: String
    let name: String
    let port: Int?
    let wildcard: Bool

    public init?(_ pattern: String) {
        var text = Substring(pattern)
        wildcard = text.hasPrefix("*.")
        if wildcard { text = text.dropFirst(2) }
        var port: Int?
        if let colon = text.lastIndex(of: ":") {
            guard let number = Int(text[text.index(after: colon)...]), (1...65_535).contains(number) else { return nil }
            port = number
            text = text[..<colon]
        }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !text.isEmpty, text.count <= 253,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-"
                    && $0.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") } }) else { return nil }
        // A wildcard covers one domain's subdomains, never a whole top-level domain.
        if wildcard, labels.count < 2 { return nil }
        self.pattern = pattern; self.name = String(text); self.port = port
    }

    public var isLocal: Bool { ["localhost", "127.0.0.1"].contains(name) }

    /// Whether `url` is an address this host allows.
    public func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        guard scheme == "https" || (scheme == "http" && isLocal) else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        guard (url.port ?? defaultPort) == (port ?? defaultPort) else { return false }
        return wildcard ? host.hasSuffix("." + name) : host == name
    }

    public static func allows(_ url: URL, hosts: [String]) -> Bool {
        hosts.compactMap(PluginHost.init).contains { $0.matches(url) }
    }
}

/// Relative paths inside a plugin's folder.
public enum PluginPath {
    /// A relative path without empty, `.` or `..` parts, hidden names, backslashes or control characters.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".") && part.utf8.count <= 255
        }
    }
}

public enum PluginError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}
