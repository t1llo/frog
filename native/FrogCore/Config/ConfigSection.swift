import Foundation

/// A plugin's settings: one table of config.toml, such as `[dictation]`, or the top-level keys
/// for the core. `init()` gives the defaults; a file only lists what differs from them.
///
/// Properties map to kebab-case keys (`muteAudio` is `mute-audio`). A nested struct is a
/// subtable (`[dictation.recording]`), a list of structs a list of inline tables, an enum with
/// String raw values a string, and a nil optional an absent key. Nested structs that are
/// sections too take their own defaults for keys a file leaves out, also inside lists.
public protocol ConfigSection: Codable, Equatable, Sendable {
    init()
    /// Comment lines written above a key or table the first time Frog writes it, by key path
    /// relative to the section: `"mode"`, `"recording.mute-audio"`, `"recording"` for the
    /// `[dictation.recording]` header, `""` for the section's own header. Lines are split at "\n".
    static var comments: [String: String] { get }
}

extension ConfigSection {
    public static var comments: [String: String] { [:] }

    static func defaultTable() throws -> ConfigTable {
        try ConfigValueEncoder.encode(Self()).value?.tableValue ?? ConfigTable()
    }
}

/// A decoded section and what the file had that it does not know.
public typealias ConfigSectionResult<T: ConfigSection> = (value: T, warnings: [ConfigWarning])

extension ConfigDocument {
    /// `[name]` decoded as `T`. Missing keys take `T()`'s values; unknown keys come back as warnings.
    public func section<T: ConfigSection>(_ name: String, as type: T.Type = T.self) throws -> ConfigSectionResult<T> {
        try decodeSection(at: [name], as: type)
    }

    /// The top-level keys decoded as `T`. Tables `T` does not know belong to other sections and are not warned about.
    public func core<T: ConfigSection>(as type: T.Type = T.self) throws -> ConfigSectionResult<T> {
        try decodeSection(at: [], as: type)
    }

    /// Writes `value` into `[name]`. Keys the file has are updated in place, even to a default
    /// value; other keys are written only when they differ from `T()`, or always with `all`.
    /// Keys `T` does not know are kept, so a newer Frog's settings survive an older one's save.
    public mutating func update<T: ConfigSection>(_ name: String, _ value: T, all: Bool = false) throws {
        try write(value, at: [name], all: all)
    }

    /// Writes `value` as the top-level keys; its nested structs become top-level tables.
    public mutating func updateCore<T: ConfigSection>(_ value: T, all: Bool = false) throws {
        try write(value, at: [], all: all)
    }

    // MARK: Plugins

    /// The `[plugins]` table: plugin ID to whether it is on.
    public func pluginSwitches() throws -> [String: Bool] {
        guard let value = value(at: ["plugins"]) else { return [:] }
        guard case .table(let table) = value else {
            throw issue(ConfigValueIssue(path: [], message: "expected a table of plugin IDs, such as dictation = true"), base: ["plugins"])
        }
        var result: [String: Bool] = [:]
        for (id, value) in table {
            guard let enabled = value.boolValue else {
                throw issue(ConfigValueIssue(path: [.key(id)], message: "expected true or false, found \(value.kindName)"), base: ["plugins"])
            }
            result[id] = enabled
        }
        return result
    }

    public mutating func setPlugin(_ id: String, enabled: Bool) throws {
        try setValue(.bool(enabled), at: ["plugins", id])
    }

    // MARK: Internals

    private func decodeSection<T: ConfigSection>(at base: [String], as type: T.Type) throws -> ConfigSectionResult<T> {
        let fileValue = value(at: base) ?? .table(ConfigTable())
        let decoder = ConfigValueDecoder()
        let decoded: T
        do { decoded = try decoder.decode(T.self, from: fileValue) }
        catch let found as ConfigValueIssue { throw issue(found, base: base) }
        let unknown = decoder.unknownKeys(in: fileValue).filter { path in
            // At the top level, unknown tables are other plugins' sections.
            !(base.isEmpty && path.count == 1 && fileValue.tableValue?[path.first!.keyName ?? ""]?.tableValue != nil)
        }
        let warnings = unknown.map { path in
            ConfigWarning(line: position(of: ConfigPath(keys: base) + path)?.line,
                          message: "\(label(ConfigPath(keys: base) + path)): unknown key, ignored by this version of Frog")
        }
        return (decoded, warnings)
    }

    private mutating func write<T: ConfigSection>(_ value: T, at base: [String], all: Bool) throws {
        let new = try ConfigValueEncoder.encode(value)
        let defaults = try ConfigValueEncoder.encode(T())
        let comments = T.comments
        let comment: ([String]) -> String? = { path in
            guard path.starts(with: base) else { return nil }
            return comments[path.dropFirst(base.count).joined(separator: ".")]
        }
        try apply(new.value?.tableValue ?? ConfigTable(), defaults: defaults.value?.tableValue, encoded: new, base: base, relative: [], all: all, comment: comment)
    }

    private mutating func apply(_ new: ConfigTable, defaults: ConfigTable?, encoded: ConfigEncoded, base: [String], relative: [String],
                                all: Bool, comment: ([String]) -> String?) throws {
        let full = base + relative
        let existing = value(at: full)?.tableValue
        for (key, item) in new {
            let path = full + [key]
            let current = existing?[key]
            // Subtables recurse, unless the file spells this one as an inline value.
            if case .table(let table) = item, current == nil || (current?.tableValue != nil && !isPair(path)) {
                try apply(table, defaults: defaults?[key]?.tableValue, encoded: encoded, base: base, relative: relative + [key], all: all, comment: comment)
                continue
            }
            if let current {
                if current != item { try setValue(item, at: path) }
            } else if all || defaults?[key] != item {
                try setValue(item, at: path, comment: comment)
            }
        }
        // A key the type knows but no longer has (a nil optional, a dictionary entry) is removed;
        // a key it does not know stays for whichever version wrote it.
        guard let existing else { return }
        let known = encoded.nilKeys[relative] ?? []
        for key in existing.keys where new[key] == nil {
            if known.contains(key) || encoded.dictionaries.contains(relative) || defaults?[key] != nil {
                try removeValue(at: full + [key])
            }
        }
    }

    /// "[dictation] mode", "[dictation.recording] mute-audio", "theme" for a top-level key.
    func label(_ path: ConfigPath) -> String {
        let keys = path.prefix { if case .key = $0 { true } else { false } }.compactMap(\.keyName)
        let header = headerPrefix(of: Array(keys))
        let rest = ConfigPath(path.dropFirst(header.count))
        if header.isEmpty { return rest.dotted }
        let name = "[" + header.map(TOMLWriter.key).joined(separator: ".") + "]"
        return rest.isEmpty ? name : name + " " + rest.dotted
    }

    func issue(_ issue: ConfigValueIssue, base: [String]) -> ConfigError {
        let path = ConfigPath(keys: base) + issue.path
        let position = self.position(of: path)
        let label = label(path)
        return ConfigError(.value, line: position?.line, column: position?.column, label.isEmpty ? issue.message : "\(label): \(issue.message)")
    }
}

extension ConfigPathComponent {
    var keyName: String? { if case .key(let key) = self { key } else { nil } }
}
