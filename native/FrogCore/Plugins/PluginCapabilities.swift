import Foundation

/// A plugin's own item in the menu bar: a symbol and an optional short title, which the page can change, and a
/// popup page Frog shows beneath it, or an action it runs when clicked.
public struct PluginMenuBar: Codable, Equatable, Sendable {
    /// An SF Symbol; the plugin's own symbol when missing.
    public var symbol: String?
    /// Text beside the symbol, such as a countdown; at most 24 characters.
    public var title: String?
    /// The page shown in a popup beneath the item, an .html file inside the plugin's folder.
    public var popup: String?
    /// Points; 200 to 480 wide and 80 to 640 tall.
    public var width: Int?
    public var height: Int?
    /// Without a popup, the action a click runs; without either, a click opens the plugin's page.
    public var action: String?

    public static let widths = 200...480
    public static let heights = 80...640
    public static let defaultWidth = 320
    public static let defaultHeight = 360

    public init(symbol: String? = nil, title: String? = nil, popup: String? = nil, width: Int? = nil, height: Int? = nil, action: String? = nil) {
        self.symbol = symbol; self.title = title; self.popup = popup; self.width = width; self.height = height; self.action = action
    }

    public var popupWidth: Int { min(max(width ?? Self.defaultWidth, Self.widths.lowerBound), Self.widths.upperBound) }
    public var popupHeight: Int { min(max(height ?? Self.defaultHeight, Self.heights.lowerBound), Self.heights.upperBound) }
}

/// One setting a plugin declares. Frog shows it in the plugin's settings and keeps its value for the plugin, which
/// reads it with `frog.settings.get`. A `secret` is kept in the Keychain and never shown again once entered.
public struct PluginSetting: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, integer, boolean, choice, secret }
    public var key: String
    public var title: String
    public var type: Kind
    public var help: String?
    /// A value of the setting's type; a secret has none.
    public var `default`: PluginSettingValue?
    public var choices: [String]?
    /// For an integer.
    public var minimum: Int?
    public var maximum: Int?

    public init(key: String, title: String, type: Kind, help: String? = nil, default value: PluginSettingValue? = nil,
                choices: [String]? = nil, minimum: Int? = nil, maximum: Int? = nil) {
        self.key = key; self.title = title; self.type = type; self.help = help; self.default = value
        self.choices = choices; self.minimum = minimum; self.maximum = maximum
    }

    private enum CodingKeys: String, CodingKey { case key, title, type, help, `default`, choices, minimum = "min", maximum = "max" }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        title = try values.decode(String.self, forKey: .title)
        let type = try values.decodeIfPresent(String.self, forKey: .type) ?? "text"
        guard let kind = Kind(rawValue: type) else {
            throw PluginError.invalid("The setting “\(key)” has the type “\(type)”. Use text, integer, boolean, choice or secret.")
        }
        self.type = kind
        help = try values.decodeIfPresent(String.self, forKey: .help)
        self.default = try values.decodeIfPresent(PluginSettingValue.self, forKey: .default)
        choices = try values.decodeIfPresent([String].self, forKey: .choices)
        minimum = try values.decodeIfPresent(Int.self, forKey: .minimum)
        maximum = try values.decodeIfPresent(Int.self, forKey: .maximum)
    }

    /// The value as this setting keeps it, or why it does not fit.
    public func accept(_ value: PluginSettingValue) throws -> PluginSettingValue {
        switch (type, value) {
        case (.text, .text(let text)), (.secret, .text(let text)):
            guard text.utf8.count <= 8_192 else { throw PluginError.invalid("“\(title)” takes at most 8 KB of text.") }
            return .text(text)
        case (.integer, .integer(let number)):
            if let minimum, number < minimum { throw PluginError.invalid("“\(title)” is at least \(minimum).") }
            if let maximum, number > maximum { throw PluginError.invalid("“\(title)” is at most \(maximum).") }
            return .integer(number)
        case (.integer, .text(let text)):
            guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { throw PluginError.invalid("“\(title)” takes a whole number.") }
            return try accept(.integer(number))
        case (.boolean, .boolean(let flag)): return .boolean(flag)
        case (.choice, .text(let text)):
            guard choices?.contains(text) == true else { throw PluginError.invalid("“\(title)” is one of \((choices ?? []).joined(separator: ", ")).") }
            return .text(text)
        default:
            throw PluginError.invalid("“\(title)” takes \(type == .boolean ? "true or false" : type == .integer ? "a whole number" : "text").")
        }
    }

    /// The value before the user changed it.
    public var initial: PluginSettingValue? {
        if let value = self.default { return value }
        switch type {
        case .boolean: return .boolean(false)
        case .choice: return choices?.first.map(PluginSettingValue.text)
        case .text: return .text("")
        case .integer: return .integer(minimum ?? 0)
        case .secret: return nil
        }
    }

    func validate() throws {
        guard PluginManifest.isValidName(key) else { throw PluginError.invalid("The setting key “\(key)” must be lowercase letters, digits and hyphens.") }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, title.count <= 40, !title.contains(where: \.isNewline) else {
            throw PluginError.invalid("The setting “\(key)” needs a title of one line and at most 40 characters.")
        }
        if let help, help.count > 120 || help.contains(where: \.isNewline) {
            throw PluginError.invalid("The help of the setting “\(key)” must be one line of at most 120 characters.")
        }
        if type == .choice {
            guard let choices, (1...20).contains(choices.count), Set(choices).count == choices.count,
                  choices.allSatisfy({ !$0.isEmpty && $0.count <= 40 && !$0.contains(where: \.isNewline) }) else {
                throw PluginError.invalid("The choice setting “\(key)” needs 1 to 20 different “choices” of up to 40 characters.")
            }
        } else if choices != nil {
            throw PluginError.invalid("Only a setting of type choice has “choices”; “\(key)” is \(type.rawValue).")
        }
        if (minimum != nil || maximum != nil), type != .integer { throw PluginError.invalid("Only an integer setting has “min” and “max”; “\(key)” is \(type.rawValue).") }
        if let minimum, let maximum, minimum > maximum { throw PluginError.invalid("The setting “\(key)” has a “min” above its “max”.") }
        if type == .secret, self.default != nil { throw PluginError.invalid("The secret “\(key)” cannot have a default: the user enters it.") }
        if let value = self.default {
            do { _ = try accept(value) } catch { throw PluginError.invalid("The default of the setting “\(key)” does not fit it: \(error.localizedDescription)") }
        }
    }
}

/// A setting's value: text, a whole number or true and false.
public enum PluginSettingValue: Codable, Equatable, Sendable {
    case text(String)
    case integer(Int)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .boolean(flag) }
        else if let number = try? value.decode(Int.self) { self = .integer(number) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else { throw PluginError.invalid("A setting's value is text, a whole number, true or false.") }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let text): try value.encode(text)
        case .integer(let number): try value.encode(number)
        case .boolean(let flag): try value.encode(flag)
        }
    }

    /// For the page: a string, a number or a boolean.
    public var json: Any {
        switch self {
        case .text(let text): text
        case .integer(let number): number
        case .boolean(let flag): flag
        }
    }

    /// A value the page sent, as JSON allows it.
    public init?(json: Any) {
        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .boolean(number.boolValue) }
            else if let exact = Int(exactly: number.doubleValue) { self = .integer(exact) }
            else { return nil }
        } else if let text = json as? String { self = .text(text) }
        else { return nil }
    }
}

/// Which of Frog's own actions a plugin may name in `uses`.
public enum PluginUses {
    /// Features whose actions run the user's own code, change Frog's shortcuts, remove apps, reach other plugins, read
    /// everything Frog kept or pair devices: no plugin may run them.
    public static let blockedPlugins: Set<String> = ["scripts", "community", "app-cleaner", "shortcuts", "history", "phone"]

    /// `windows.move` or `windows.*`.
    public static func isValidPattern(_ pattern: String) -> Bool {
        let parts = pattern.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, PluginManifest.isValidName(parts[0]), !blockedPlugins.contains(parts[0]) else { return false }
        return parts[1] == "*" || PluginManifest.isValidName(parts[1])
    }

    /// Whether the action `id` is one the patterns allow.
    public static func allows(_ id: String, patterns: [String]) -> Bool {
        let plugin = String(id.prefix { $0 != "." })
        guard !blockedPlugins.contains(plugin) else { return false }
        return patterns.contains { $0 == id || ($0.hasSuffix(".*") && $0.dropLast(2) == plugin) }
    }
}

extension PluginManifest {
    /// Checks the menu bar item, shortcuts, settings and `uses` against the permissions that allow them.
    func validateCapabilities() throws {
        let has = Set(permissions)
        if let menubar {
            guard has.contains(.menubar) else { throw PluginError.invalid("“menubar” needs the menubar permission.") }
            if let symbol = menubar.symbol, !Self.isValidSymbol(symbol) {
                throw PluginError.invalid("The menu bar symbol “\(symbol)” must be an SF Symbol name, such as timer.")
            }
            if let title = menubar.title, title.count > 24 || title.contains(where: \.isNewline) {
                throw PluginError.invalid("The menu bar title must be one line of at most 24 characters.")
            }
            if let popup = menubar.popup {
                guard PluginPath.isSafe(popup), popup.lowercased().hasSuffix(".html") || popup.lowercased().hasSuffix(".htm") else {
                    throw PluginError.invalid("The menu bar popup “\(popup)” must be an .html file inside the plugin's folder.")
                }
                if menubar.action != nil { throw PluginError.invalid("A menu bar item has a popup or an action, not both.") }
            }
            if let width = menubar.width, !PluginMenuBar.widths.contains(width) { throw PluginError.invalid("The popup's width must be 200 to 480.") }
            if let height = menubar.height, !PluginMenuBar.heights.contains(height) { throw PluginError.invalid("The popup's height must be 80 to 640.") }
            if let action = menubar.action {
                guard let found = actions.first(where: { $0.id == action }) else {
                    throw PluginError.invalid("The menu bar action “\(action)” is not one of the plugin's actions.")
                }
                if found.parameters.contains(where: { $0.required == true }) {
                    throw PluginError.invalid("The menu bar action “\(action)” needs parameters, which a click cannot give.")
                }
            }
            if menubar.popup == nil, menubar.action == nil, entry == nil {
                throw PluginError.invalid("A menu bar item needs a popup, an action or the plugin's page to open.")
            }
        } else if has.contains(.menubar) {
            throw PluginError.invalid("The menubar permission needs a “menubar” item.")
        }

        let shortcuts = actions.filter { $0.shortcut != nil }
        if !shortcuts.isEmpty, !has.contains(.hotkeys) { throw PluginError.invalid("An action's “shortcut” needs the hotkeys permission.") }
        if has.contains(.hotkeys), shortcuts.isEmpty { throw PluginError.invalid("The hotkeys permission needs an action with a “shortcut”.") }
        var keys = Set<String>()
        for action in shortcuts {
            let text = action.shortcut ?? ""
            guard let shortcut = try? Shortcut(text) else {
                throw PluginError.invalid("The shortcut “\(text)” of “\(action.id)” must look like ctrl+alt+f: modifiers, then one key.")
            }
            // cmd, option and control in Carbon's bits; shift alone would take a key from typing.
            guard shortcut.modifiers & 0x1900 != 0 else { throw PluginError.invalid("The shortcut of “\(action.id)” needs at least one of ctrl, alt and cmd.") }
            guard keys.insert(shortcut.description).inserted else { throw PluginError.invalid("Two actions have the shortcut \(shortcut).") }
            if action.parameters.contains(where: { $0.required == true }) {
                throw PluginError.invalid("The action “\(action.id)” needs parameters, which a shortcut cannot give.")
            }
        }

        guard settings.count <= 20 else { throw PluginError.invalid("A plugin can have at most 20 settings.") }
        guard Set(settings.map(\.key)).count == settings.count else { throw PluginError.invalid("Two settings have the same key.") }
        for setting in settings { try setting.validate() }

        if !uses.isEmpty, !has.contains(.frogActions) { throw PluginError.invalid("“uses” needs the frog-actions permission.") }
        if has.contains(.frogActions), uses.isEmpty { throw PluginError.invalid("The frog-actions permission needs the Frog actions it runs, in “uses”.") }
        guard uses.count <= 30, Set(uses).count == uses.count else { throw PluginError.invalid("“uses” lists at most 30 different actions.") }
        for pattern in uses where !PluginUses.isValidPattern(pattern) {
            let plugin = String(pattern.prefix { $0 != "." })
            if PluginUses.blockedPlugins.contains(plugin) {
                throw PluginError.invalid("Plugins cannot run \(plugin) actions, so “\(pattern)” cannot be in “uses”.")
            }
            throw PluginError.invalid("“\(pattern)” in “uses” must be a Frog action id, such as windows.move, or a feature's actions, such as windows.*.")
        }
    }

    public static func isValidSymbol(_ symbol: String) -> Bool {
        !symbol.isEmpty && symbol.count <= 60 && symbol.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }
    }
}
