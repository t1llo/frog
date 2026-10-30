import Foundation

/// A line of the file, or several lines for a value that spans them. Entries cover the file
/// exactly, terminators included, so joining their bytes gives the file back.
struct TOMLEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case blank
        case comment
        case header([String])
        /// `value` is the byte range of the value's spelling in the whole file.
        case pair(table: [String], key: String, value: Range<Int>)
    }
    var kind: Kind
    var range: Range<Int>
    /// The line it starts on, from 1.
    var line: Int

    var isPair: Bool { if case .pair = kind { true } else { false } }
    var isHeader: Bool { if case .header = kind { true } else { false } }
    var isBlank: Bool { kind == .blank }
    var isComment: Bool { kind == .comment }
    var headerPath: [String]? { if case .header(let path) = kind { path } else { nil } }
}

struct TOMLPosition: Sendable, Equatable {
    var line: Int
    var column: Int
}

struct TOMLParsed: Sendable {
    var entries: [TOMLEntry] = []
    var root = ConfigTable()
    /// Where each value starts, by its path from the root; header tables map to their header.
    var positions: [ConfigPath: TOMLPosition] = [:]
    /// Tables with a `[header]` of their own.
    var headers: Set<[String]> = []
    /// "\r\n" when the file's first line ends that way, otherwise "\n".
    var newline = "\n"
}

/// Reads the TOML subset described in docs/config-format.md. It works on UTF-8 bytes, so every
/// entry's range is exact; columns count characters.
struct TOMLParser {
    private let bytes: [UInt8]
    private var index = 0
    private var line = 1
    private var lineStart = 0
    private var parsed = TOMLParsed()
    private enum Definition { case explicitTable, implicitTable, value }
    private var definitions: [[String]: (kind: Definition, line: Int)] = [:]
    private var table: [String] = []

    static func parse(_ bytes: [UInt8]) throws -> TOMLParsed {
        var parser = TOMLParser(bytes: bytes)
        try parser.run()
        return parser.parsed
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    // MARK: Lines

    private mutating func run() throws {
        if let firstNewline = bytes.firstIndex(of: 0x0A), firstNewline > 0, bytes[firstNewline - 1] == 0x0D { parsed.newline = "\r\n" }
        // A byte order mark is kept as the start of the first line.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3; lineStart = 3 }
        while index < bytes.count {
            let start = index == 3 && bytes.starts(with: [0xEF, 0xBB, 0xBF]) && parsed.entries.isEmpty ? 0 : index
            let startLine = line
            skipSpaces()
            let kind: TOMLEntry.Kind
            if atLineEnd {
                kind = .blank
            } else if peek == UInt8(ascii: "#") {
                try skipComment()
                kind = .comment
            } else if peek == UInt8(ascii: "[") {
                kind = .header(try header())
            } else {
                kind = try pair()
            }
            try endLine()
            parsed.entries.append(TOMLEntry(kind: kind, range: start..<index, line: startLine))
        }
    }

    private mutating func header() throws -> [String] {
        let position = here
        index += 1
        if peek == UInt8(ascii: "[") {
            throw error("lists of tables ([[...]]) are not supported; use a list of inline tables, such as items = [{ name = \"a\" }]")
        }
        var path: [String] = []
        while true {
            skipSpaces()
            path.append(try key())
            skipSpaces()
            if peek == UInt8(ascii: ".") { index += 1; continue }
            guard peek == UInt8(ascii: "]") else { throw error("expected ']' to close the table name") }
            index += 1
            break
        }
        try define(table: path, at: position)
        table = path
        try afterValue()
        return path
    }

    private mutating func define(table path: [String], at position: TOMLPosition) throws {
        for depth in 1..<path.count {
            let prefix = Array(path.prefix(depth))
            switch definitions[prefix]?.kind {
            case .value?:
                throw error("'\(prefix.joined(separator: "."))' is already set to a value on line \(definitions[prefix]!.line), so it cannot hold a table", at: position)
            case nil: definitions[prefix] = (.implicitTable, position.line)
            default: break
            }
        }
        if let existing = definitions[path] {
            switch existing.kind {
            case .explicitTable: throw error("duplicate table [\(path.joined(separator: "."))]; it is already on line \(existing.line)", at: position)
            case .value: throw error("'\(path.joined(separator: "."))' is already set to a value on line \(existing.line)", at: position)
            case .implicitTable: break
            }
        }
        definitions[path] = (.explicitTable, position.line)
        parsed.headers.insert(path)
        if parsed.root.value(at: path) == nil { parsed.root.setValue(.table(ConfigTable()), at: path) }
        parsed.positions[ConfigPath(keys: path)] = position
    }

    private mutating func pair() throws -> TOMLEntry.Kind {
        let keyPosition = here
        let name = try key()
        skipSpaces()
        if peek == UInt8(ascii: ".") {
            throw error("dotted keys such as '\(name).…' are not supported; put the key under a [\(name)] table")
        }
        guard peek == UInt8(ascii: "=") else {
            throw error(atLineEnd ? "expected '=' and a value after '\(name)'" : "expected '=' after '\(name)'")
        }
        index += 1
        skipSpaces()
        guard !atLineEnd, peek != UInt8(ascii: "#") else { throw error("expected a value after '='") }
        let path = table + [name]
        if let existing = definitions[path] {
            throw error(existing.kind == .value
                ? "duplicate key '\(name)'; it is already set on line \(existing.line)"
                : "'\(name)' is already a table (line \(existing.line))", at: keyPosition)
        }
        let start = index
        let value = try self.value(path: ConfigPath(keys: path))
        let range = start..<index
        definitions[path] = (.value, keyPosition.line)
        parsed.root.setValue(value, at: path)
        try afterValue()
        return .pair(table: table, key: name, value: range)
    }

    /// After a value or header only a comment may follow on its line.
    private mutating func afterValue() throws {
        skipSpaces()
        if peek == UInt8(ascii: "#") { try skipComment() }
        guard atLineEnd else { throw error("unexpected text after the value; start a comment with '#'") }
    }

    private mutating func endLine() throws {
        if index >= bytes.count { return }
        if bytes[index] == 0x0D {
            guard index + 1 < bytes.count, bytes[index + 1] == 0x0A else { throw error("a carriage return must be followed by a line feed") }
            index += 1
        }
        guard bytes[index] == 0x0A else { throw error("unexpected text after the value") }
        index += 1
        newLine()
    }

    // MARK: Keys

    private mutating func key() throws -> String {
        guard let byte = peek else { throw error("expected a key") }
        switch byte {
        case UInt8(ascii: "\""): return try basicString()
        case UInt8(ascii: "'"): return try literalString()
        default:
            let start = index
            while let byte = peek, Self.isBareKeyByte(byte) { index += 1 }
            guard index > start else {
                throw error(byte == UInt8(ascii: "=") ? "expected a key before '='" : "unexpected '\(character)'; keys use letters, digits, '-' and '_', or quotes")
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }

    private static func isBareKeyByte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2D
    }

    // MARK: Values

    private mutating func value(path: ConfigPath) throws -> ConfigValue {
        parsed.positions[path] = here
        guard let byte = peek else { throw error("expected a value") }
        switch byte {
        case UInt8(ascii: "\""):
            return .string(try startsWith("\"\"\"") ? multilineBasicString() : basicString())
        case UInt8(ascii: "'"):
            return .string(try startsWith("'''") ? multilineLiteralString() : literalString())
        case UInt8(ascii: "["): return try array(path: path)
        case UInt8(ascii: "{"): return try inlineTable(path: path)
        case UInt8(ascii: "t"), UInt8(ascii: "f"):
            if startsWithWord("true") { index += 4; return .bool(true) }
            if startsWithWord("false") { index += 5; return .bool(false) }
            return try number()
        default: return try number()
        }
    }

    private mutating func array(path: ConfigPath) throws -> ConfigValue {
        index += 1
        var items: [ConfigValue] = []
        while true {
            try skipBlankSpace()
            if peek == UInt8(ascii: "]") { index += 1; return .array(items) }
            guard peek != nil else { throw error("the list is missing its closing ']'") }
            items.append(try value(path: path + [.index(items.count)]))
            try skipBlankSpace()
            if peek == UInt8(ascii: ",") { index += 1; continue }
            if peek == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw error(peek == nil ? "the list is missing its closing ']'" : "expected ',' or ']' in the list")
        }
    }

    private mutating func inlineTable(path: ConfigPath) throws -> ConfigValue {
        index += 1
        var table = ConfigTable()
        skipSpaces()
        if peek == UInt8(ascii: "}") { index += 1; return .table(table) }
        while true {
            skipSpaces()
            if atLineEnd { throw error("an inline table must close on the line it opens; use a [table] for longer ones") }
            if peek == UInt8(ascii: "}") { throw error("an inline table takes no comma before '}'") }
            let keyPosition = here
            let name = try key()
            skipSpaces()
            if peek == UInt8(ascii: ".") { throw error("dotted keys such as '\(name).…' are not supported") }
            guard peek == UInt8(ascii: "=") else { throw error("expected '=' after '\(name)'") }
            index += 1
            skipSpaces()
            guard !atLineEnd, peek != UInt8(ascii: "#") else { throw error("expected a value after '='") }
            guard table[name] == nil else { throw error("duplicate key '\(name)' in the inline table", at: keyPosition) }
            table[name] = try value(path: path + [.key(name)])
            skipSpaces()
            if peek == UInt8(ascii: ",") { index += 1; continue }
            if peek == UInt8(ascii: "}") { index += 1; return .table(table) }
            throw error(atLineEnd ? "an inline table must close on the line it opens; use a [table] for longer ones" : "expected ',' or '}' in the inline table")
        }
    }

    private mutating func number() throws -> ConfigValue {
        let start = index
        while let byte = peek, Self.isBareKeyByte(byte) || [UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: ":")].contains(byte) { index += 1 }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard !token.isEmpty else {
            if peek == UInt8(ascii: "=") { throw error("expected a value after '='") }
            throw error("expected a value, found '\(character)'; strings need quotes, such as \"text\"")
        }
        func fail(_ message: String) -> ConfigError { error(message, at: TOMLPosition(line: line, column: column(of: start))) }
        if token.contains(":") || token.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            throw fail("dates and times are not supported; write them as a string")
        }
        switch token {
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where token.hasPrefix(prefix) {
            let digits = String(token.dropFirst(2))
            guard Self.validUnderscores(digits), let value = Int(digits.replacingOccurrences(of: "_", with: ""), radix: radix) else {
                throw fail("'\(token)' is not a valid number")
            }
            return .integer(value)
        }
        let decimal = #"^[+-]?(0|[1-9](_?[0-9])*)"#
        if token.range(of: decimal + "$", options: .regularExpression) != nil {
            guard let value = Int(token.replacingOccurrences(of: "_", with: "")) else { throw fail("'\(token)' is too large for an integer") }
            return .integer(value)
        }
        let float = decimal + #"((\.[0-9](_?[0-9])*)([eE][+-]?[0-9](_?[0-9])*)?|[eE][+-]?[0-9](_?[0-9])*)$"#
        if token.range(of: float, options: .regularExpression) != nil, let value = Double(token.replacingOccurrences(of: "_", with: "")) {
            return .float(value)
        }
        if let first = token.first, first.isLetter {
            throw fail("expected a value, found '\(token)'; strings need quotes, such as \"\(token)\"")
        }
        throw fail("'\(token)' is not a valid number")
    }

    private static func validUnderscores(_ digits: String) -> Bool {
        !digits.isEmpty && !digits.hasPrefix("_") && !digits.hasSuffix("_") && !digits.contains("__")
    }

    // MARK: Strings

    private mutating func basicString() throws -> String {
        index += 1
        var out: [UInt8] = []
        while true {
            guard let byte = peek, byte != 0x0A, byte != 0x0D else { throw error("the string is missing its closing quote") }
            index += 1
            switch byte {
            case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"): out += try escape()
            default:
                try checkControl(byte)
                out.append(byte)
            }
        }
    }

    private mutating func literalString() throws -> String {
        index += 1
        let start = index
        while true {
            guard let byte = peek, byte != 0x0A, byte != 0x0D else { throw error("the string is missing its closing quote") }
            if byte == UInt8(ascii: "'") { break }
            try checkControl(byte)
            index += 1
        }
        defer { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func multilineBasicString() throws -> String {
        index += 3
        skipFirstNewline()
        var out: [UInt8] = []
        while true {
            guard let byte = peek else { throw error("the multi-line string is missing its closing \"\"\"") }
            if byte == UInt8(ascii: "\""), startsWith("\"\"\"") {
                let quotes = countQuotes(UInt8(ascii: "\""))
                guard quotes <= 5 else { throw error("too many quotes in a row; escape one as \\\"") }
                out += Array(repeating: UInt8(ascii: "\""), count: quotes - 3)
                index += quotes
                return String(decoding: out, as: UTF8.self)
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                if trimLineEndingBackslash() { continue }
                out += try escape()
                continue
            }
            if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2; newLine(); out.append(0x0A); continue
            }
            if byte == 0x0A { index += 1; newLine(); out.append(0x0A); continue }
            try checkControl(byte)
            out.append(byte)
            index += 1
        }
    }

    private mutating func multilineLiteralString() throws -> String {
        index += 3
        skipFirstNewline()
        var out: [UInt8] = []
        while true {
            guard let byte = peek else { throw error("the multi-line string is missing its closing '''") }
            if byte == UInt8(ascii: "'"), startsWith("'''") {
                let quotes = countQuotes(UInt8(ascii: "'"))
                guard quotes <= 5 else { throw error("too many quotes in a row") }
                out += Array(repeating: UInt8(ascii: "'"), count: quotes - 3)
                index += quotes
                return String(decoding: out, as: UTF8.self)
            }
            if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2; newLine(); out.append(0x0A); continue
            }
            if byte == 0x0A { index += 1; newLine(); out.append(0x0A); continue }
            try checkControl(byte)
            out.append(byte)
            index += 1
        }
    }

    private mutating func skipFirstNewline() {
        if peek == 0x0A { index += 1; newLine() }
        else if peek == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; newLine() }
    }

    private func countQuotes(_ quote: UInt8) -> Int {
        var count = 0
        while index + count < bytes.count, bytes[index + count] == quote { count += 1 }
        return count
    }

    /// A backslash at the end of a line in a multi-line string joins it with the next non-blank text.
    private mutating func trimLineEndingBackslash() -> Bool {
        var probe = index
        while probe < bytes.count, bytes[probe] == 0x20 || bytes[probe] == 0x09 { probe += 1 }
        guard probe < bytes.count, bytes[probe] == 0x0A || bytes[probe] == 0x0D else { return false }
        index = probe
        while let byte = peek, [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            index += 1
            if byte == 0x0A { newLine() }
        }
        return true
    }

    private mutating func escape() throws -> [UInt8] {
        let position = TOMLPosition(line: line, column: column(of: index - 1))
        guard let byte = peek else { throw error("the string is missing its closing quote") }
        index += 1
        switch byte {
        case UInt8(ascii: "b"): return [0x08]
        case UInt8(ascii: "t"): return [0x09]
        case UInt8(ascii: "n"): return [0x0A]
        case UInt8(ascii: "f"): return [0x0C]
        case UInt8(ascii: "r"): return [0x0D]
        case UInt8(ascii: "\""): return [0x22]
        case UInt8(ascii: "\\"): return [0x5C]
        case UInt8(ascii: "u"), UInt8(ascii: "U"):
            let count = byte == UInt8(ascii: "u") ? 4 : 8
            guard index + count <= bytes.count,
                  let code = UInt32(String(decoding: bytes[index..<index + count], as: UTF8.self), radix: 16),
                  let scalar = Unicode.Scalar(code) else {
                throw error("expected \(count) hex digits of a Unicode character after \\\(Character(Unicode.Scalar(byte)))", at: position)
            }
            index += count
            return Array(String(scalar).utf8)
        default:
            throw error("unknown escape '\\\(Character(Unicode.Scalar(byte)))'; use \\\\ for a backslash", at: position)
        }
    }

    private func checkControl(_ byte: UInt8) throws {
        if (byte < 0x20 && byte != 0x09) || byte == 0x7F { throw error("control characters must be escaped, such as \\u0001") }
    }

    // MARK: Scanning

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    /// The whole character at the current position, for messages.
    private var character: String {
        var end = index + 1
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
        return String(decoding: bytes[index..<min(end, bytes.count)], as: UTF8.self)
    }
    private var atLineEnd: Bool { peek == nil || peek == 0x0A || peek == 0x0D }

    private func startsWith(_ text: String) -> Bool {
        let probe = Array(text.utf8)
        return index + probe.count <= bytes.count && Array(bytes[index..<index + probe.count]) == probe
    }

    private func startsWithWord(_ word: String) -> Bool {
        guard startsWith(word) else { return false }
        let end = index + word.utf8.count
        return end >= bytes.count || !Self.isBareKeyByte(bytes[end])
    }

    private mutating func skipSpaces() {
        while let byte = peek, byte == 0x20 || byte == 0x09 { index += 1 }
    }

    private mutating func skipComment() throws {
        while let byte = peek, byte != 0x0A, byte != 0x0D {
            if (byte < 0x20 && byte != 0x09) || byte == 0x7F { throw error("control characters are not allowed in comments") }
            index += 1
        }
    }

    /// Spaces, line breaks and comments between the items of a list.
    private mutating func skipBlankSpace() throws {
        while true {
            skipSpaces()
            if peek == UInt8(ascii: "#") { try skipComment() }
            if peek == 0x0A || peek == 0x0D { try endLine(); continue }
            return
        }
    }

    private mutating func newLine() { line += 1; lineStart = index }

    private func column(of offset: Int) -> Int {
        bytes[lineStart..<min(offset, bytes.count)].reduce(1) { $0 + (($1 & 0xC0) == 0x80 ? 0 : 1) }
    }

    private var here: TOMLPosition { TOMLPosition(line: line, column: column(of: index)) }

    private func error(_ message: String, at position: TOMLPosition? = nil) -> ConfigError {
        let position = position ?? here
        return ConfigError(.syntax, line: position.line, column: position.column, message)
    }
}
