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
        case .links: "Opens web links in your default browser, which can send what is in the link to that site."
        case .network: "Sends requests to the sites listed below, and only those. It can send them anything the plugin can read."
        case .ai: "Sends text to the model your Writing rules use by default. A cloud model's provider bills you for it."
        case .scripts: "Runs the scripts shown below with your full access to this Mac: your files, apps and accounts, and the permissions you gave Frog, such as Accessibility. Install it only if you trust the author and have read the scripts."
        }
    }

    /// Permissions that can send data off the Mac or act beyond the sandbox, shown with a caution.
    public var isSensitive: Bool { [.clipboardRead, .network, .ai, .scripts].contains(self) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// An action a plugin adds: like a built-in plugin's, it joins `frog actions` and `frog run`, the command bar and
/// shortcuts, as `community.<plugin id>.<id>`. The page answers it with `frog.action(id, handler)`.
public struct PluginManifestAction: Codable, Equatable, Sendable {
    /// What running it may change. Frog refuses a call the effect does not cover while the action runs.
    public enum Effect: String, Codable, CaseIterable, Comparable, Sendable {
        /// Reads its storage or, with permission, the clipboard. Changes nothing.
        case read
        /// Also changes something on this Mac: its storage, the clipboard, a notification, a script, a link.
        case write
        /// Also reaches the internet or the AI model.
        case network

        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public struct Parameter: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case text, integer, boolean, choice }
        public var name: String
        public var type: Kind
        public var required: Bool?
        public var help: String?
        /// The values a `choice` takes.
        public var choices: [String]?

        public init(name: String, type: Kind = .text, required: Bool? = nil, help: String? = nil, choices: [String]? = nil) {
            self.name = name; self.type = type; self.required = required; self.help = help; self.choices = choices
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            type = try values.decodeIfPresent(Kind.self, forKey: .type) ?? .text
            required = try values.decodeIfPresent(Bool.self, forKey: .required)
            help = try values.decodeIfPresent(String.self, forKey: .help)
            choices = try values.decodeIfPresent([String].self, forKey: .choices)
        }
    }

    public var id: String
    public var title: String
    public var effect: Effect
    public var parameters: [Parameter]
    /// Takes text: from standard input with `frog run --stdin`, or the text selected in the command bar.
    public var input: Bool?
    public var keywords: String?

    public init(id: String, title: String, effect: Effect, parameters: [Parameter] = [], input: Bool? = nil, keywords: String? = nil) {
        self.id = id; self.title = title; self.effect = effect; self.parameters = parameters; self.input = input; self.keywords = keywords
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        let effect = try values.decode(String.self, forKey: .effect)
        guard let known = Effect(rawValue: effect) else {
            throw PluginError.invalid("The action “\(id)” has the effect “\(effect)”. Use read, write or network.")
        }
        self.effect = known
        parameters = try values.decodeIfPresent([Parameter].self, forKey: .parameters) ?? []
        input = try values.decodeIfPresent(Bool.self, forKey: .input)
        keywords = try values.decodeIfPresent(String.self, forKey: .keywords)
    }

    /// Option names `frog run` keeps for itself.
    static let reservedNames: Set<String> = ["stdin", "json", "help"]
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
    public var actions: [PluginManifestAction]

    public static let fileName = "plugin.json"
    public static let defaultSymbol = "puzzlepiece.extension"
    public var displaySymbol: String { symbol ?? Self.defaultSymbol }

    public init(id: String, name: String, version: String = "1.0.0", description: String, author: String? = nil, homepage: String? = nil,
                symbol: String? = nil, entry: String? = "index.html", frog: String? = nil, permissions: [PluginPermission] = [],
                hosts: [String] = [], scripts: [String: String] = [:], commands: [PluginCommand] = [], actions: [PluginManifestAction] = []) {
        self.id = id; self.name = name; self.version = version; self.description = description; self.author = author
        self.homepage = homepage; self.symbol = symbol; self.entry = entry; self.frog = frog; self.permissions = permissions
        self.hosts = hosts; self.scripts = scripts; self.commands = commands; self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, homepage, symbol, entry, frog, permissions, hosts, scripts, commands, actions
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
        actions = try values.decodeIfPresent([PluginManifestAction].self, forKey: .actions) ?? []
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
        if !actions.isEmpty { try values.encode(actions, forKey: .actions) }
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
        try validateActions()
        if entry == nil {
            guard !commands.isEmpty || !actions.isEmpty else { throw PluginError.invalid("A plugin needs a page (“entry”), commands or actions.") }
        }
    }

    private func validateActions() throws {
        guard actions.count <= 20 else { throw PluginError.invalid("A plugin can have at most 20 actions.") }
        if !actions.isEmpty, entry == nil { throw PluginError.invalid("Actions need a page (“entry”) that answers them with frog.action.") }
        let names = commands.map(\.id) + actions.map(\.id)
        guard Set(names).count == names.count else { throw PluginError.invalid("Two commands or actions have the same id.") }
        for action in actions {
            guard Self.isValidName(action.id) else { throw PluginError.invalid("The action id “\(action.id)” must be lowercase letters, digits and hyphens.") }
            try Self.check(action.title, "action title", maximum: 60)
            if let keywords = action.keywords, keywords.count > 120 { throw PluginError.invalid("An action's keywords must be at most 120 characters.") }
            if action.effect == .network, !permissions.contains(.network), !permissions.contains(.ai) {
                throw PluginError.invalid("The action “\(action.id)” has the network effect, which needs the network or ai permission.")
            }
            guard action.parameters.count <= 8 else { throw PluginError.invalid("The action “\(action.id)” can have at most 8 parameters.") }
            guard Set(action.parameters.map(\.name)).count == action.parameters.count else {
                throw PluginError.invalid("The action “\(action.id)” names a parameter twice.")
            }
            for parameter in action.parameters {
                guard Self.isValidName(parameter.name), !PluginManifestAction.reservedNames.contains(parameter.name) else {
                    throw PluginError.invalid("The parameter “\(parameter.name)” of “\(action.id)” must be lowercase letters, digits and hyphens, and not stdin, json or help.")
                }
                if let help = parameter.help { try Self.check(help, "help of “\(parameter.name)”", maximum: 120) }
                if parameter.type == .choice {
                    guard let choices = parameter.choices, (1...20).contains(choices.count), Set(choices).count == choices.count,
                          choices.allSatisfy({ !$0.isEmpty && $0.count <= 40 && !$0.contains(where: \.isNewline) }) else {
                        throw PluginError.invalid("The choice “\(parameter.name)” of “\(action.id)” needs 1 to 20 different “choices” of up to 40 characters.")
                    }
                } else if parameter.choices != nil {
                    throw PluginError.invalid("Only a parameter of type choice has “choices”; “\(parameter.name)” of “\(action.id)” is \(parameter.type.rawValue).")
                }
            }
        }
    }

    /// The access the plugin asks for, given the SHA-256 of each of its scripts.
    public func grant(scriptHashes: [String: String]) -> PluginGrant {
        var pinned = scripts.keys.reduce(into: [String: String]()) { $0[$1] = scriptHashes[$1] ?? "" }
        if !scripts.isEmpty { pinned[PluginGrant.filesKey] = scriptHashes[PluginGrant.filesKey] ?? "" }
        return PluginGrant(permissions: permissions, hosts: hosts, scripts: pinned)
    }

    /// Whether this Frog version is new enough, for a version such as "1.0.40"; a development build always is.
    public func runs(on frogVersion: String) -> Bool {
        guard let frog, let needed = PluginVersion(frog), let current = PluginVersion(frogVersion) else { return true }
        return current >= needed
    }

    public static func isValidID(_ id: String) -> Bool {
        guard (3...64).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }) else { return false }
        // Every dot-separated part is a host name label: it neither starts nor ends with a hyphen.
        return id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-"
        }
    }

    public static func isValidName(_ name: String) -> Bool {
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
        // A wildcard covers one domain's subdomains, never a whole top-level domain or a range of addresses.
        if wildcard, labels.count < 2 || labels.last!.allSatisfy(\.isNumber) { return nil }
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
