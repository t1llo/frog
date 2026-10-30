import Foundation

/// config.toml as its owner wrote it, with the changes Frog makes on top.
///
/// Rendering a document that was not changed gives back the exact bytes it was read from. A
/// change rewrites only what it has to: a new value replaces the old spelling between `=` and the
/// line's comment, a new key goes after the last key of its table, a new table goes at the end
/// (or after its parent's family of tables), and removing a key removes its line and nothing else.
/// Keys before the first `[table]` belong to the core.
public struct ConfigDocument: Sendable, Equatable {
    private(set) var bytes: [UInt8]
    private var parsed: TOMLParsed

    /// An empty file.
    public init() {
        bytes = []
        parsed = TOMLParsed()
    }

    public init(parsing text: String) throws {
        try self.init(bytes: Array(text.utf8))
    }

    /// Reads UTF-8 bytes; anything else is refused with a `.syntax` error.
    public init(data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else {
            throw ConfigError(.syntax, "config.toml must be UTF-8 text")
        }
        try self.init(bytes: Array(data))
    }

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        parsed = try TOMLParser.parse(bytes)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }

    /// The file's text, with the user's comments, spacing and line endings.
    public var text: String { String(decoding: bytes, as: UTF8.self) }
    public var data: Data { Data(bytes) }

    /// Every value of the file. Top-level keys are the core settings; each `[table]` is a key of it.
    public var root: ConfigTable { parsed.root }

    public func value(at path: [String]) -> ConfigValue? {
        path.isEmpty ? .table(parsed.root) : parsed.root.value(at: path)
    }

    /// Whether `path` has a `[header]` line of its own.
    public func hasHeader(_ path: [String]) -> Bool { parsed.headers.contains(path) }

    // MARK: Editing

    /// Sets the value at a key path such as `["dictation", "mode"]`. An existing key keeps its
    /// place, indentation and comment; a table value is written key by key, merging with what the
    /// table already holds. `comment` gives the comment lines for a key or table the change
    /// creates, by its full path; it is never asked about keys that already exist.
    public mutating func setValue(_ value: ConfigValue, at path: [String], comment: ([String]) -> String? = { _ in nil }) throws {
        guard !path.isEmpty else {
            guard case .table(let table) = value else { throw ConfigError(.value, "the top level of the file is a table") }
            for (key, item) in table { try setValue(item, at: [key], comment: comment) }
            return
        }
        if let index = pairIndex(path) {
            try replaceValue(ofEntry: index, with: value)
            return
        }
        for depth in stride(from: path.count - 1, to: 0, by: -1) {
            let prefix = Array(path.prefix(depth))
            guard let index = pairIndex(prefix) else { continue }
            guard case .table(var table)? = parsed.root.value(at: prefix), table.setValue(value, at: Array(path.dropFirst(depth))) else {
                throw ConfigError(.value, line: parsed.entries[index].line, "'\(prefix.joined(separator: "."))' is not a table, so it cannot hold '\(path.last!)'")
            }
            try replaceValue(ofEntry: index, with: .table(table))
            return
        }
        if case .table(let table) = value {
            if table.isEmpty, parsed.root.value(at: path) == nil { try insertTable(path, comment: comment) }
            for (key, item) in table { try setValue(item, at: path + [key], comment: comment) }
            return
        }
        try insertPair(path, value: value, comment: comment)
    }

    /// Removes the key at `path`: its line, or the tables under it when it is a table.
    public mutating func removeValue(at path: [String]) throws {
        guard !path.isEmpty else { return }
        if let index = pairIndex(path) {
            try splice(parsed.entries[index].range, with: [])
            return
        }
        for depth in stride(from: path.count - 1, to: 0, by: -1) {
            let prefix = Array(path.prefix(depth))
            guard let index = pairIndex(prefix) else { continue }
            guard case .table(var table)? = parsed.root.value(at: prefix), table.value(at: Array(path.dropFirst(depth))) != nil else { return }
            table.setValue(nil, at: Array(path.dropFirst(depth)))
            try replaceValue(ofEntry: index, with: .table(table))
            return
        }
        // Each header under the path, last first, so earlier byte ranges stay valid.
        let blocks = parsed.entries.indices.filter { parsed.entries[$0].headerPath?.starts(with: path) == true }
        var result = bytes
        for header in blocks.reversed() {
            let end = contentEnd(ofBlockAt: header)
            let lower = parsed.entries[header].range.lowerBound
            let upper = end < parsed.entries.count ? parsed.entries[end].range.lowerBound : bytes.count
            result.replaceSubrange(lower..<upper, with: [])
        }
        if !blocks.isEmpty { try reparse(result) }
    }

    // MARK: Positions

    /// The line and column of the value at `path`, or of the closest enclosing value the file has.
    func position(of path: ConfigPath) -> TOMLPosition? {
        var path = path
        while true {
            if let position = parsed.positions[path] { return position }
            guard !path.isEmpty else { return nil }
            path.removeLast()
        }
    }

    /// The deepest table of `keys` that has a header, which messages name in brackets.
    func headerPrefix(of keys: [String]) -> [String] {
        for depth in stride(from: keys.count, to: 0, by: -1) where parsed.headers.contains(Array(keys.prefix(depth))) {
            return Array(keys.prefix(depth))
        }
        return []
    }

    // MARK: Internals

    /// Whether `path` is a `key = value` line, such as a table written inline.
    func isPair(_ path: [String]) -> Bool { pairIndex(path) != nil }

    private func pairIndex(_ path: [String]) -> Int? {
        let table = Array(path.dropLast()), key = path.last!
        return parsed.entries.firstIndex { entry in
            if case .pair(table, key, _) = entry.kind { true } else { false }
        }
    }

    private var newline: [UInt8] { Array(parsed.newline.utf8) }

    private func indentation(ofEntry index: Int) -> String {
        let range = parsed.entries[index].range
        return String(decoding: bytes[range].prefix { $0 == 0x20 || $0 == 0x09 }, as: UTF8.self)
    }

    private mutating func replaceValue(ofEntry index: Int, with value: ConfigValue) throws {
        guard case .pair(_, _, let range) = parsed.entries[index].kind else { return }
        let wasMultiline = bytes[range].contains(0x0A)
        let spelling = TOMLWriter.value(value, indent: indentation(ofEntry: index), multilineList: wasMultiline && value.arrayValue != nil)
        try splice(range, with: Array(spelling.utf8))
    }

    private func lines(_ text: String?, indent: String) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.isEmpty ? indent + "#" : indent + "# " + line
        }
    }

    private func pairLine(_ key: String, _ value: ConfigValue, indent: String) -> String {
        indent + TOMLWriter.key(key) + " = " + TOMLWriter.value(value, indent: indent)
    }

    private mutating func insertPair(_ path: [String], value: ConfigValue, comment: ([String]) -> String?) throws {
        let table = Array(path.dropLast()), key = path.last!
        var text: [String] = []
        let index: Int
        if table.isEmpty || parsed.headers.contains(table) {
            let found = table.isEmpty ? rootInsertion() : blockInsertion(table)
            index = found.index
            let previous = index > 0 ? parsed.entries[index - 1] : nil
            let indent = found.lastPair.map(indentation(ofEntry:)) ?? ""
            let commentLines = lines(comment(path), indent: indent)
            // A commented key after another key, or the first key after the file's own heading, gets air.
            if previous?.isPair == true && !commentLines.isEmpty { text.append("") }
            if table.isEmpty, found.lastPair == nil, previous?.isComment == true { text.append("") }
            text += commentLines
            text.append(pairLine(key, value, indent: indent))
            if table.isEmpty, found.lastPair == nil, index < parsed.entries.count, !parsed.entries[index].isBlank { text.append("") }
        } else {
            let found = tableInsertion(table)
            index = found.index
            if found.blankBefore { text.append("") }
            text += lines(comment(table), indent: "")
            text.append(TOMLWriter.header(table))
            text += lines(comment(path), indent: "")
            text.append(pairLine(key, value, indent: ""))
            if found.blankAfter { text.append("") }
        }
        try insert(text, atEntry: index)
    }

    /// Writes `[table]` on its own, for a table set without keys.
    private mutating func insertTable(_ table: [String], comment: ([String]) -> String?) throws {
        let found = tableInsertion(table)
        var text: [String] = []
        if found.blankBefore { text.append("") }
        text += lines(comment(table), indent: "")
        text.append(TOMLWriter.header(table))
        if found.blankAfter { text.append("") }
        try insert(text, atEntry: found.index)
    }

    private mutating func insert(_ lines: [String], atEntry index: Int) throws {
        let offset = index < parsed.entries.count ? parsed.entries[index].range.lowerBound : bytes.count
        var inserted: [UInt8] = []
        // The last line of a file may lack its line break; the new lines go after one.
        if offset == bytes.count, let last = bytes.last, last != 0x0A { inserted += newline }
        for line in lines { inserted += Array(line.utf8) + newline }
        try splice(offset..<offset, with: inserted)
    }

    /// After the last key before the first table; in a file without keys, after its heading.
    private func rootInsertion() -> (index: Int, lastPair: Int?) {
        let entries = parsed.entries
        let firstHeader = entries.firstIndex(where: \.isHeader) ?? entries.count
        if let last = entries[..<firstHeader].lastIndex(where: \.isPair) { return (last + 1, last) }
        var index = firstHeader
        if firstHeader < entries.count { index = attachedCommentsStart(before: firstHeader, notBefore: 0) }
        while index > 0, entries[index - 1].isBlank { index -= 1 }
        return (index, nil)
    }

    /// After the table's last key, so before the blank lines and comments that lead to the next table.
    private func blockInsertion(_ table: [String]) -> (index: Int, lastPair: Int?) {
        let entries = parsed.entries
        let header = entries.firstIndex { $0.headerPath == table }!
        let end = entries[(header + 1)...].firstIndex(where: \.isHeader) ?? entries.count
        if let last = entries[(header + 1)..<end].lastIndex(where: \.isPair) { return (last + 1, last) }
        // Comments right under the header describe this table, unless they run into the next one.
        var run = header + 1
        while run < end, entries[run].isComment { run += 1 }
        return (run < end || end == entries.count ? run : header + 1, nil)
    }

    /// Where a table without a header goes: before its own subtables, after its parent's family
    /// of tables, or at the end of the file.
    private func tableInsertion(_ table: [String]) -> (index: Int, blankBefore: Bool, blankAfter: Bool) {
        let entries = parsed.entries
        func placed(_ index: Int) -> (Int, Bool, Bool) {
            (index, index > 0 && !entries[index - 1].isBlank, index < entries.count && !entries[index].isBlank)
        }
        if let first = entries.firstIndex(where: { $0.headerPath.map { $0.count > table.count && $0.starts(with: table) } == true }) {
            return placed(attachedCommentsStart(before: first, notBefore: 0))
        }
        for depth in stride(from: table.count - 1, to: 0, by: -1) {
            let ancestor = Array(table.prefix(depth))
            guard let last = entries.lastIndex(where: { $0.headerPath?.starts(with: ancestor) == true }) else { continue }
            var index = contentEnd(ofBlockAt: last)
            while index > last + 1, entries[index - 1].isBlank { index -= 1 }
            return placed(index)
        }
        return (entries.count, !entries.isEmpty && !entries.last!.isBlank && !(bytes.isEmpty), false)
    }

    /// The end of the block a header starts, leaving out comments that belong to the next header.
    private func contentEnd(ofBlockAt header: Int) -> Int {
        let entries = parsed.entries
        guard let next = entries[(header + 1)...].firstIndex(where: \.isHeader) else { return entries.count }
        return attachedCommentsStart(before: next, notBefore: header + 1)
    }

    /// Comment lines directly above a header, without a blank line between, belong to it.
    private func attachedCommentsStart(before header: Int, notBefore floor: Int) -> Int {
        var index = header
        while index > floor, parsed.entries[index - 1].isComment { index -= 1 }
        return index
    }

    private mutating func splice(_ range: Range<Int>, with replacement: [UInt8]) throws {
        var result = bytes
        result.replaceSubrange(range, with: replacement)
        try reparse(result)
    }

    private mutating func reparse(_ result: [UInt8]) throws {
        do { parsed = try TOMLParser.parse(result) }
        catch {
            // Frog's own spelling always reads back; a failure here is a bug, and the file is kept.
            throw ConfigError(.value, "Frog could not write this change as valid TOML: \(error)")
        }
        bytes = result
    }
}
