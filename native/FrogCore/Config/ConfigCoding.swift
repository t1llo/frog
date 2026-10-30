import Foundation

/// Swift property names and config.toml keys: `muteAudio` is `mute-audio`, `llmURL` is `llm-url`.
public enum ConfigKeys {
    public static func kebab(_ name: String) -> String {
        let characters = Array(name)
        var out = ""
        for (index, character) in characters.enumerated() {
            if character.isUppercase, index > 0 {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // A new word starts after a lowercase letter or digit, or where an acronym ends: "URLPath".
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) { out += "-" }
            }
            out += character.lowercased()
        }
        return out
    }

    /// The reverse spelling, as near as it goes: `mute-audio` is `muteAudio`.
    public static func camel(_ key: String) -> String {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first else { return key }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

/// A problem with one value while converting it, at a path from the table being converted.
struct ConfigValueIssue: Error {
    var path: ConfigPath
    var message: String
}

// MARK: - Dictionaries

/// Dictionaries keep their keys as written: plugin IDs such as `command-bar` are data, not property names.
protocol ConfigStringDictionaryEncodable {
    var configEntries: [(key: String, value: any Encodable)] { get }
}
protocol ConfigStringDictionaryDecodable {
    static func configDecode(_ table: ConfigTable, _ decoder: ConfigValueDecoder, path: ConfigPath) throws -> Self
}
extension Dictionary: ConfigStringDictionaryEncodable where Key == String, Value: Encodable {
    var configEntries: [(key: String, value: any Encodable)] { sorted { $0.key < $1.key }.map { ($0.key, $0.value as any Encodable) } }
}
extension Dictionary: ConfigStringDictionaryDecodable where Key == String, Value: Decodable {
    static func configDecode(_ table: ConfigTable, _ decoder: ConfigValueDecoder, path: ConfigPath) throws -> Self {
        decoder.state.opened.insert(path)
        var result: Self = [:]
        for (key, value) in table {
            decoder.state.accessed.insert(path + [.key(key)])
            result[key] = try decoder.unbox(Value.self, from: value, path: path + [.key(key)])
        }
        return result
    }
}

// MARK: - Encoding

/// What encoding a value produced, with what the value tree alone cannot say: which keys the type
/// knows but left empty (nil optionals), and which tables are dictionaries whose keys are all data.
struct ConfigEncoded {
    var value: ConfigValue?
    /// Keys of nil optionals, by the key path of their table.
    var nilKeys: [[String]: Set<String>] = [:]
    var dictionaries: Set<[String]> = []
}

enum ConfigValueEncoder {
    static func encode(_ value: any Encodable) throws -> ConfigEncoded {
        let slot = Slot()
        try box(value, into: slot, codingPath: [])
        var encoded = ConfigEncoded()
        encoded.value = try slot.materialize(path: [], into: &encoded)
        return encoded
    }

    static func box(_ value: any Encodable, into slot: Slot, codingPath: [any CodingKey]) throws {
        switch value {
        case let value as ConfigValue: slot.content = .value(value)
        case let url as URL: slot.content = .value(.string(url.isFileURL ? url.path : url.absoluteString))
        case let dictionary as any ConfigStringDictionaryEncodable:
            let table = TableBox()
            table.isDictionary = true
            slot.content = .table(table)
            for (key, item) in dictionary.configEntries {
                try box(item, into: table.slot(key), codingPath: codingPath + [AnyCodingKey(key)])
            }
        default:
            try value.encode(to: ValueEncoder(slot: slot, codingPath: codingPath))
        }
    }

    final class Slot {
        enum Content { case empty, value(ConfigValue), table(TableBox), array(ArrayBox) }
        var content = Content.empty

        func materialize(path: [String], into encoded: inout ConfigEncoded) throws -> ConfigValue? {
            switch content {
            case .empty: return nil
            case .value(let value): return value
            case .table(let box):
                if !box.nilKeys.isEmpty { encoded.nilKeys[path, default: []].formUnion(box.nilKeys) }
                if box.isDictionary { encoded.dictionaries.insert(path) }
                var table = ConfigTable()
                for key in box.keys {
                    if let value = try box.slots[key]!.materialize(path: path + [key], into: &encoded) { table[key] = value }
                }
                return .table(table)
            case .array(let box):
                var items: [ConfigValue] = []
                for slot in box.slots {
                    // Paths inside lists are not tracked: a list is always written as a whole.
                    var ignored = ConfigEncoded()
                    guard let item = try slot.materialize(path: [], into: &ignored) else {
                        throw EncodingError.invalidValue(Optional<Int>.none as Any, .init(codingPath: [], debugDescription: "config.toml lists cannot hold empty values"))
                    }
                    items.append(item)
                }
                return .array(items)
            }
        }

        func table() -> TableBox {
            if case .table(let box) = content { return box }
            let box = TableBox()
            content = .table(box)
            return box
        }

        func array() -> ArrayBox {
            if case .array(let box) = content { return box }
            let box = ArrayBox()
            content = .array(box)
            return box
        }
    }

    final class TableBox {
        var keys: [String] = []
        var slots: [String: Slot] = [:]
        var nilKeys: Set<String> = []
        var isDictionary = false
        func slot(_ key: String) -> Slot {
            if let slot = slots[key] { return slot }
            let slot = Slot()
            keys.append(key)
            slots[key] = slot
            nilKeys.remove(key)
            return slot
        }
    }

    final class ArrayBox { var slots: [Slot] = [] }

    struct ValueEncoder: Encoder {
        let slot: Slot
        let codingPath: [any CodingKey]
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            KeyedEncodingContainer(Keyed<Key>(table: slot.table(), codingPath: codingPath))
        }
        func unkeyedContainer() -> any UnkeyedEncodingContainer { Unkeyed(array: slot.array(), codingPath: codingPath) }
        func singleValueContainer() -> any SingleValueEncodingContainer { Single(slot: slot, codingPath: codingPath) }
    }

    static func integer<T: BinaryInteger>(_ value: T, _ codingPath: [any CodingKey]) throws -> ConfigValue {
        guard let integer = Int(exactly: value) else {
            throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "\(value) is too large for config.toml"))
        }
        return .integer(integer)
    }

    struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let table: TableBox
        let codingPath: [any CodingKey]
        private func name(_ key: Key) -> String { table.isDictionary ? key.stringValue : ConfigKeys.kebab(key.stringValue) }
        private func set(_ value: ConfigValue, _ key: Key) { table.slot(name(key)).content = .value(value) }

        mutating func encodeNil(forKey key: Key) throws { if table.slots[name(key)] == nil { table.nilKeys.insert(name(key)) } }
        mutating func encode(_ value: Bool, forKey key: Key) throws { set(.bool(value), key) }
        mutating func encode(_ value: String, forKey key: Key) throws { set(.string(value), key) }
        mutating func encode(_ value: Double, forKey key: Key) throws { set(.float(value), key) }
        mutating func encode(_ value: Float, forKey key: Key) throws { set(.float(Double("\(value)") ?? Double(value)), key) }
        mutating func encode(_ value: Int, forKey key: Key) throws { set(.integer(value), key) }
        mutating func encode(_ value: Int8, forKey key: Key) throws { set(try integer(value, codingPath), key) }
        mutating func encode(_ value: Int16, forKey key: Key) throws { set(try integer(value, codingPath), key) }
        mutating func encode(_ value: Int32, forKey key: Key) throws { set(try integer(value, codingPath), key) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { set(try integer(value, codingPath), key) }
        mutating func encode(_ value: UInt, forKey key: Key) throws { set(try integer(value, codingPath), key) }
        mutating func encode(_ value: UInt8, forKey key: Key) throws { set(try integer(value, codingPath), key) }
        mutating func encode(_ value: UInt16, forKey key: Key) throws { set(try integer(value, codingPath), key) }
        mutating func encode(_ value: UInt32, forKey key: Key) throws { set(try integer(value, codingPath), key) }
        mutating func encode(_ value: UInt64, forKey key: Key) throws { set(try integer(value, codingPath), key) }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            try box(value, into: table.slot(name(key)), codingPath: codingPath + [key])
        }

        // A nil optional is recorded, so that an update can remove the key the file still has.
        private mutating func present<T: Encodable>(_ value: T?, _ key: Key) throws {
            if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
        }
        mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws { try present(value, key) }
        mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws { try present(value, key) }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            KeyedEncodingContainer(Keyed<NestedKey>(table: table.slot(name(key)).table(), codingPath: codingPath + [key]))
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            Unkeyed(array: table.slot(name(key)).array(), codingPath: codingPath + [key])
        }
        mutating func superEncoder() -> any Encoder { ValueEncoder(slot: table.slot("super"), codingPath: codingPath) }
        mutating func superEncoder(forKey key: Key) -> any Encoder { ValueEncoder(slot: table.slot(name(key)), codingPath: codingPath + [key]) }
    }

    struct Unkeyed: UnkeyedEncodingContainer {
        let array: ArrayBox
        let codingPath: [any CodingKey]
        var count: Int { array.slots.count }
        private func next() -> Slot { let slot = Slot(); array.slots.append(slot); return slot }
        private mutating func append(_ value: ConfigValue) { next().content = .value(value) }

        mutating func encodeNil() throws {
            throw EncodingError.invalidValue(Optional<Int>.none as Any, .init(codingPath: codingPath, debugDescription: "config.toml lists cannot hold empty values"))
        }
        mutating func encode(_ value: Bool) throws { append(.bool(value)) }
        mutating func encode(_ value: String) throws { append(.string(value)) }
        mutating func encode(_ value: Double) throws { append(.float(value)) }
        mutating func encode(_ value: Float) throws { append(.float(Double("\(value)") ?? Double(value))) }
        mutating func encode(_ value: Int) throws { append(.integer(value)) }
        mutating func encode(_ value: Int8) throws { append(try integer(value, codingPath)) }
        mutating func encode(_ value: Int16) throws { append(try integer(value, codingPath)) }
        mutating func encode(_ value: Int32) throws { append(try integer(value, codingPath)) }
        mutating func encode(_ value: Int64) throws { append(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt) throws { append(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt8) throws { append(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt16) throws { append(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt32) throws { append(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt64) throws { append(try integer(value, codingPath)) }
        mutating func encode<T: Encodable>(_ value: T) throws {
            try box(value, into: next(), codingPath: codingPath + [AnyCodingKey(index: count)])
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            KeyedEncodingContainer(Keyed<NestedKey>(table: next().table(), codingPath: codingPath))
        }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { Unkeyed(array: next().array(), codingPath: codingPath) }
        mutating func superEncoder() -> any Encoder { ValueEncoder(slot: next(), codingPath: codingPath) }
    }

    struct Single: SingleValueEncodingContainer {
        let slot: Slot
        let codingPath: [any CodingKey]
        private func set(_ value: ConfigValue) { slot.content = .value(value) }

        mutating func encodeNil() throws { slot.content = .empty }
        mutating func encode(_ value: Bool) throws { set(.bool(value)) }
        mutating func encode(_ value: String) throws { set(.string(value)) }
        mutating func encode(_ value: Double) throws { set(.float(value)) }
        mutating func encode(_ value: Float) throws { set(.float(Double("\(value)") ?? Double(value))) }
        mutating func encode(_ value: Int) throws { set(.integer(value)) }
        mutating func encode(_ value: Int8) throws { set(try integer(value, codingPath)) }
        mutating func encode(_ value: Int16) throws { set(try integer(value, codingPath)) }
        mutating func encode(_ value: Int32) throws { set(try integer(value, codingPath)) }
        mutating func encode(_ value: Int64) throws { set(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt) throws { set(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt8) throws { set(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt16) throws { set(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt32) throws { set(try integer(value, codingPath)) }
        mutating func encode(_ value: UInt64) throws { set(try integer(value, codingPath)) }
        mutating func encode<T: Encodable>(_ value: T) throws { try box(value, into: slot, codingPath: codingPath) }
    }
}

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { stringValue = string }
    init(index: Int) { stringValue = "[\(index)]"; intValue = index }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.init(index: intValue) }
}

// MARK: - Decoding

/// Decodes values of config.toml and notes which keys the type asked for: the others are unknown.
final class ConfigValueDecoder {
    final class State {
        var accessed: Set<ConfigPath> = []
        /// Tables and lists the type looked into key by key. A value taken whole, such as a raw
        /// `ConfigValue`, has no unknown keys inside it.
        var opened: Set<ConfigPath> = []
    }
    let state = State()

    func decode<T: Decodable>(_ type: T.Type, from value: ConfigValue) throws -> T {
        try unbox(type, from: value, path: [])
    }

    /// Keys the file has that decoding never asked for, outermost only.
    func unknownKeys(in value: ConfigValue, path: ConfigPath = []) -> [ConfigPath] {
        guard state.opened.contains(path) else { return [] }
        switch value {
        case .table(let table):
            return table.flatMap { key, item -> [ConfigPath] in
                let child = path + [.key(key)]
                return state.accessed.contains(child) ? unknownKeys(in: item, path: child) : [child]
            }
        case .array(let items):
            return items.enumerated().flatMap { unknownKeys(in: $1, path: path + [.index($0)]) }
        default: return []
        }
    }

    func unbox<T: Decodable>(_ type: T.Type, from value: ConfigValue, path: ConfigPath) throws -> T {
        if T.self == ConfigValue.self { return value as! T }
        if T.self == URL.self {
            guard case .string(let string) = value, let url = string.hasPrefix("/") || string.hasPrefix("~")
                ? URL(fileURLWithPath: (string as NSString).expandingTildeInPath) : URL(string: string) else {
                throw ConfigValueIssue(path: path, message: "expected a URL or a path, found \(value.kindName)")
            }
            return url as! T
        }
        if let dictionary = T.self as? any ConfigStringDictionaryDecodable.Type {
            guard case .table(let table) = value else { throw ConfigValueIssue(path: path, message: "expected a table, found \(value.kindName)") }
            return try dictionary.configDecode(table, self, path: path) as! T
        }
        if let choices = configChoices(T.self) {
            guard case .string(let string) = value, choices.contains(string) else {
                throw ConfigValueIssue(path: path, message: "expected one of \(choices.joined(separator: ", "))")
            }
        }
        var value = value
        // A nested section takes its own defaults for the keys it leaves out, inside lists too.
        if let section = T.self as? any ConfigSection.Type, case .table(let table) = value {
            value = .table(try section.defaultTable().overlaid(with: table))
        }
        do {
            return try T(from: ValueDecoder(value: value, path: path, owner: self))
        } catch let error as DecodingError {
            switch error {
            case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
                throw ConfigValueIssue(path: path, message: context.debugDescription)
            case .keyNotFound(let key, _):
                throw ConfigValueIssue(path: path, message: "missing key '\(ConfigKeys.kebab(key.stringValue))'")
            @unknown default:
                throw ConfigValueIssue(path: path, message: "\(error)")
            }
        }
    }

    struct ValueDecoder: Decoder {
        let value: ConfigValue
        let path: ConfigPath
        let owner: ConfigValueDecoder
        var codingPath: [any CodingKey] { path.map { component in
            switch component {
            case .key(let key): AnyCodingKey(key)
            case .index(let index): AnyCodingKey(index: index)
            }
        } }
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
            guard case .table(let table) = value else { throw ConfigValueIssue(path: path, message: "expected a table, found \(value.kindName)") }
            owner.state.opened.insert(path)
            return KeyedDecodingContainer(Keyed<Key>(table: table, path: path, owner: owner))
        }
        func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
            guard case .array(let items) = value else { throw ConfigValueIssue(path: path, message: "expected a list, found \(value.kindName)") }
            owner.state.opened.insert(path)
            return Unkeyed(items: items, path: path, owner: owner)
        }
        func singleValueContainer() throws -> any SingleValueDecodingContainer { Single(value: value, path: path, owner: owner) }
    }

    static func primitive<T>(_ type: T.Type, _ value: ConfigValue, _ path: ConfigPath) throws -> T {
        func mismatch(_ expected: String) -> ConfigValueIssue {
            ConfigValueIssue(path: path, message: "expected \(expected), found \(value.kindName)")
        }
        switch type {
        case is Bool.Type:
            guard let bool = value.boolValue else { throw mismatch("true or false") }
            return bool as! T
        case is String.Type:
            guard let string = value.stringValue else { throw mismatch("a string") }
            return string as! T
        case is Double.Type:
            guard let double = value.doubleValue else { throw mismatch("a number") }
            return double as! T
        case is Float.Type:
            guard let double = value.doubleValue else { throw mismatch("a number") }
            return Float(double) as! T
        default:
            guard let integer = value.integerValue else { throw mismatch("an integer") }
            func fit<I: FixedWidthInteger>(_: I.Type) throws -> I {
                guard let fitted = I(exactly: integer) else {
                    throw ConfigValueIssue(path: path, message: "expected an integer from \(I.min) to \(I.max)")
                }
                return fitted
            }
            switch type {
            case is Int.Type: return integer as! T
            case is Int8.Type: return try fit(Int8.self) as! T
            case is Int16.Type: return try fit(Int16.self) as! T
            case is Int32.Type: return try fit(Int32.self) as! T
            case is Int64.Type: return try fit(Int64.self) as! T
            case is UInt.Type: return try fit(UInt.self) as! T
            case is UInt8.Type: return try fit(UInt8.self) as! T
            case is UInt16.Type: return try fit(UInt16.self) as! T
            case is UInt32.Type: return try fit(UInt32.self) as! T
            default: return try fit(UInt64.self) as! T
            }
        }
    }

    struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let table: ConfigTable
        let path: ConfigPath
        let owner: ConfigValueDecoder
        var codingPath: [any CodingKey] { ValueDecoder(value: .table(table), path: path, owner: owner).codingPath }
        var allKeys: [Key] { table.keys.compactMap { Key(stringValue: $0) ?? Key(stringValue: ConfigKeys.camel($0)) } }

        private func lookup(_ key: Key) -> (name: String, value: ConfigValue)? {
            let kebab = ConfigKeys.kebab(key.stringValue)
            if let value = table[kebab] { return (kebab, value) }
            if let value = table[key.stringValue] { return (key.stringValue, value) }
            return nil
        }
        private func found(_ key: Key) throws -> (name: String, value: ConfigValue) {
            guard let entry = lookup(key) else {
                throw ConfigValueIssue(path: path, message: "missing key '\(ConfigKeys.kebab(key.stringValue))'")
            }
            owner.state.accessed.insert(path + [.key(entry.name)])
            return entry
        }

        func contains(_ key: Key) -> Bool {
            guard let entry = lookup(key) else { return false }
            owner.state.accessed.insert(path + [.key(entry.name)])
            return true
        }
        func decodeNil(forKey key: Key) throws -> Bool { lookup(key) == nil }
        func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decode(type, key) }
        func decode(_ type: String.Type, forKey key: Key) throws -> String { try decode(type, key) }
        func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decode(type, key) }
        func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decode(type, key) }
        func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decode(type, key) }
        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decode(type, key) }
        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decode(type, key) }
        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decode(type, key) }
        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decode(type, key) }
        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decode(type, key) }
        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decode(type, key) }
        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decode(type, key) }
        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decode(type, key) }
        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decode(type, key) }
        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try decode(type, key) }

        private func decode<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T {
            let entry = try found(key)
            return try owner.unbox(type, from: entry.value, path: path + [.key(entry.name)])
        }

        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            let entry = try found(key)
            return try ValueDecoder(value: entry.value, path: path + [.key(entry.name)], owner: owner).container(keyedBy: type)
        }
        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            let entry = try found(key)
            return try ValueDecoder(value: entry.value, path: path + [.key(entry.name)], owner: owner).unkeyedContainer()
        }
        func superDecoder() throws -> any Decoder { ValueDecoder(value: .table(table), path: path, owner: owner) }
        func superDecoder(forKey key: Key) throws -> any Decoder {
            let entry = try found(key)
            return ValueDecoder(value: entry.value, path: path + [.key(entry.name)], owner: owner)
        }
    }

    struct Unkeyed: UnkeyedDecodingContainer {
        let items: [ConfigValue]
        let path: ConfigPath
        let owner: ConfigValueDecoder
        var currentIndex = 0
        var codingPath: [any CodingKey] { ValueDecoder(value: .array(items), path: path, owner: owner).codingPath }
        var count: Int? { items.count }
        var isAtEnd: Bool { currentIndex >= items.count }

        private mutating func next() throws -> (value: ConfigValue, path: ConfigPath) {
            guard !isAtEnd else { throw ConfigValueIssue(path: path, message: "the list has too few items") }
            defer { currentIndex += 1 }
            return (items[currentIndex], path + [.index(currentIndex)])
        }
        mutating func decodeNil() throws -> Bool { false }
        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            let item = try next()
            return try owner.unbox(type, from: item.value, path: item.path)
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
            let item = try next()
            return try ValueDecoder(value: item.value, path: item.path, owner: owner).container(keyedBy: type)
        }
        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
            let item = try next()
            return try ValueDecoder(value: item.value, path: item.path, owner: owner).unkeyedContainer()
        }
        mutating func superDecoder() throws -> any Decoder {
            let item = try next()
            return ValueDecoder(value: item.value, path: item.path, owner: owner)
        }
    }

    struct Single: SingleValueDecodingContainer {
        let value: ConfigValue
        let path: ConfigPath
        let owner: ConfigValueDecoder
        var codingPath: [any CodingKey] { ValueDecoder(value: value, path: path, owner: owner).codingPath }
        func decodeNil() -> Bool { false }
        func decode(_ type: Bool.Type) throws -> Bool { try primitive(type, value, path) }
        func decode(_ type: String.Type) throws -> String { try primitive(type, value, path) }
        func decode(_ type: Double.Type) throws -> Double { try primitive(type, value, path) }
        func decode(_ type: Float.Type) throws -> Float { try primitive(type, value, path) }
        func decode(_ type: Int.Type) throws -> Int { try primitive(type, value, path) }
        func decode(_ type: Int8.Type) throws -> Int8 { try primitive(type, value, path) }
        func decode(_ type: Int16.Type) throws -> Int16 { try primitive(type, value, path) }
        func decode(_ type: Int32.Type) throws -> Int32 { try primitive(type, value, path) }
        func decode(_ type: Int64.Type) throws -> Int64 { try primitive(type, value, path) }
        func decode(_ type: UInt.Type) throws -> UInt { try primitive(type, value, path) }
        func decode(_ type: UInt8.Type) throws -> UInt8 { try primitive(type, value, path) }
        func decode(_ type: UInt16.Type) throws -> UInt16 { try primitive(type, value, path) }
        func decode(_ type: UInt32.Type) throws -> UInt32 { try primitive(type, value, path) }
        func decode(_ type: UInt64.Type) throws -> UInt64 { try primitive(type, value, path) }
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try owner.unbox(type, from: value, path: path) }
    }
}

/// The spellings of an enum with String raw values, for "expected one of toggle, hold".
private func configChoices<T>(_ type: T.Type) -> [String]? {
    guard let choice = type as? any (CaseIterable & RawRepresentable).Type else { return nil }
    return rawStrings(choice)
}

private func rawStrings<E: CaseIterable & RawRepresentable>(_ type: E.Type) -> [String]? {
    let names = E.allCases.compactMap { $0.rawValue as? String }
    return names.isEmpty || names.count != E.allCases.count ? nil : names
}

// MARK: - ConfigValue in other coders

extension ConfigValue: Codable {
    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var table = ConfigTable()
            for key in keyed.allKeys { table[key.stringValue] = try keyed.decode(ConfigValue.self, forKey: key) }
            self = .table(table)
        } else if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [ConfigValue] = []
            while !unkeyed.isAtEnd { items.append(try unkeyed.decode(ConfigValue.self)) }
            self = .array(items)
        } else {
            let single = try decoder.singleValueContainer()
            if let bool = try? single.decode(Bool.self) { self = .bool(bool) }
            else if let integer = try? single.decode(Int.self) { self = .integer(integer) }
            else if let double = try? single.decode(Double.self) { self = .float(double) }
            else { self = .string(try single.decode(String.self)) }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .bool(let bool): var single = encoder.singleValueContainer(); try single.encode(bool)
        case .integer(let integer): var single = encoder.singleValueContainer(); try single.encode(integer)
        case .float(let double): var single = encoder.singleValueContainer(); try single.encode(double)
        case .string(let string): var single = encoder.singleValueContainer(); try single.encode(string)
        case .array(let items):
            var unkeyed = encoder.unkeyedContainer()
            for item in items { try unkeyed.encode(item) }
        case .table(let table):
            var keyed = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, item) in table { try keyed.encode(item, forKey: AnyCodingKey(key)) }
        }
    }
}
