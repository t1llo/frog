import Foundation

/// One value of config.toml. TOML has no null: an absent key is how a file says "no value".
public enum ConfigValue: Sendable, Equatable {
    case bool(Bool)
    case integer(Int)
    case float(Double)
    case string(String)
    case array([ConfigValue])
    case table(ConfigTable)

    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var integerValue: Int? { if case .integer(let value) = self { value } else { nil } }
    /// An integer reads as a number too, so `transparency = 1` is accepted where 1.0 is.
    public var doubleValue: Double? {
        switch self {
        case .float(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var arrayValue: [ConfigValue]? { if case .array(let value) = self { value } else { nil } }
    public var tableValue: ConfigTable? { if case .table(let value) = self { value } else { nil } }

    /// How messages name the kind of a value: "found a string".
    var kindName: String {
        switch self {
        case .bool: "true or false"
        case .integer: "an integer"
        case .float: "a number"
        case .string: "a string"
        case .array: "a list"
        case .table: "a table"
        }
    }
}

extension ConfigValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .float(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: ConfigValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ConfigValue)...) {
        var table = ConfigTable()
        for (key, value) in elements { table[key] = value }
        self = .table(table)
    }
}

/// A TOML table that keeps the order its keys were added in, which is the order they are written.
/// Two tables are equal when they hold the same keys and values, in any order.
public struct ConfigTable: Sendable, Equatable, ExpressibleByDictionaryLiteral, Sequence {
    public private(set) var keys: [String] = []
    private var values: [String: ConfigValue] = [:]

    public init() {}
    public init(dictionaryLiteral elements: (String, ConfigValue)...) {
        for (key, value) in elements { self[key] = value }
    }

    /// Setting a new key appends it; setting nil removes it.
    public subscript(key: String) -> ConfigValue? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func makeIterator() -> AnyIterator<(key: String, value: ConfigValue)> {
        var index = keys.startIndex
        return AnyIterator {
            guard index < keys.endIndex else { return nil }
            defer { index += 1 }
            return (keys[index], values[keys[index]]!)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.values == rhs.values }

    /// The value at a key path, such as `["dictation", "recording", "mute-audio"]`.
    public func value(at path: [String]) -> ConfigValue? {
        guard let first = path.first else { return .table(self) }
        guard let value = self[first] else { return nil }
        if path.count == 1 { return value }
        return value.tableValue?.value(at: Array(path.dropFirst()))
    }

    /// Sets a value at a key path, creating the tables on the way. Returns false when a key on the
    /// way holds something other than a table.
    @discardableResult
    mutating func setValue(_ value: ConfigValue?, at path: [String]) -> Bool {
        guard let first = path.first else { return false }
        if path.count == 1 { self[first] = value; return true }
        var nested: ConfigTable
        switch self[first] {
        case nil: nested = ConfigTable()
        case .table(let table)?: nested = table
        default: return false
        }
        guard nested.setValue(value, at: Array(path.dropFirst())) else { return false }
        self[first] = .table(nested)
        return true
    }

    /// `overrides` laid over this table: tables merge key by key, anything else is replaced.
    func overlaid(with overrides: ConfigTable) -> ConfigTable {
        var result = self
        for (key, value) in overrides {
            if case .table(let base)? = result[key], case .table(let top) = value {
                result[key] = .table(base.overlaid(with: top))
            } else {
                result[key] = value
            }
        }
        return result
    }
}

/// A step of a path into a value: a key of a table or a position in a list.
enum ConfigPathComponent: Hashable, Sendable, CustomStringConvertible {
    case key(String)
    case index(Int)
    var description: String {
        switch self {
        case .key(let key): key
        case .index(let index): "[\(index)]"
        }
    }
}

typealias ConfigPath = [ConfigPathComponent]

extension Array where Element == ConfigPathComponent {
    init(keys: [String]) { self = keys.map { .key($0) } }
    /// `recording.mute-audio`, `items[2].name`. Keys that need quotes in TOML are quoted.
    var dotted: String {
        var text = ""
        for component in self {
            switch component {
            case .key(let key):
                if !text.isEmpty { text += "." }
                text += TOMLWriter.key(key)
            case .index(let index): text += "[\(index)]"
            }
        }
        return text
    }
}

/// What a line of config.toml got wrong. `line` and `column` count from 1.
public struct ConfigError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// The file is not valid TOML, or uses TOML this subset does not read.
        case syntax
        /// A value does not fit the setting it is for.
        case value
        /// The file could not be read or written.
        case file
        /// The file changed on disk and its new version does not read, so nothing was saved.
        case externalEdit
    }
    public var kind: Kind
    public var line: Int?
    public var column: Int?
    /// The message without the line, such as "expected a value after '='".
    public var message: String

    public init(_ kind: Kind, line: Int? = nil, column: Int? = nil, _ message: String) {
        self.kind = kind; self.line = line; self.column = column; self.message = message
    }

    /// "line 12: expected a value after '='".
    public var description: String { line.map { "line \($0): \(message)" } ?? message }
    public var errorDescription: String? { description }
}

/// Something a file says that this version of Frog does not use, such as a key a newer version
/// added. Warnings never stop a file from loading.
public struct ConfigWarning: Equatable, Sendable, CustomStringConvertible {
    public var line: Int?
    public var message: String
    public init(line: Int?, message: String) { self.line = line; self.message = message }
    public var description: String { line.map { "line \($0): \(message)" } ?? message }
}
