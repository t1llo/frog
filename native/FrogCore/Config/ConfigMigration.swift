import Foundation

/// Writes config.toml once from the version-1 files, `config` (key = value) and `config.json`.
///
/// It produces the core keys and the `[plugins]` table itself; each plugin adds its own table
/// through `register`, mapping from the decoded v1 `Configuration`, in which every key the old
/// files left out already has its old default. The old files are only read: they stay where
/// they are, and the app renames them once it runs on config.toml.
public struct ConfigMigration: Sendable {
    public typealias Mapping = @Sendable (Configuration) throws -> ConfigTable
    private var sections: [(name: String, write: @Sendable (Configuration, inout ConfigDocument) throws -> Void)] = []

    public init() {}

    /// A plugin's table from its v1 settings. Every key the mapping returns is written, in its order.
    public mutating func register(section name: String, _ mapping: @escaping Mapping) {
        sections.append((name, { legacy, document in
            let table = try mapping(legacy)
            guard !table.isEmpty else { return }
            try document.setValue(.table(table), at: [name])
        }))
    }

    /// A plugin's table as its section type; keys equal to the type's defaults are left out.
    public mutating func register<T: ConfigSection>(section name: String, as type: T.Type, _ mapping: @escaping @Sendable (Configuration) throws -> T) {
        sections.append((name, { legacy, document in try document.update(name, mapping(legacy)) }))
    }

    /// The v1 files of `directory` as one `Configuration`, or nil when it has neither.
    public static func readLegacy(from directory: URL) throws -> Configuration? {
        let text = try ConfigFile.read(directory.appendingPathComponent("config"))?.data
        let json = try ConfigFile.read(directory.appendingPathComponent("config.json"))?.data
        if let text {
            guard let string = String(data: text, encoding: .utf8) else { throw ConfigError(.file, "config must be UTF-8 text") }
            // A config without config.json starts from the configuration Frog would have created.
            var first = Configuration()
            first.preferences.toolkit = ToolkitPreferences()
            return try TextConfiguration.decode(string, companion: json ?? ConfigurationFile.encode(first))
        }
        if let json { return try ConfigurationFile.decode(json) }
        return nil
    }

    /// config.toml for a v1 configuration, without writing anything.
    public func document(from legacy: Configuration) throws -> ConfigDocument {
        var document = try ConfigDocument(parsing: Self.heading)
        try document.setValue(.table(Self.pluginsTable(from: legacy)), at: ["plugins"])
        try document.setValue(.table(Self.coreTable(from: legacy)), at: [])
        for section in sections { try section.write(legacy, &document) }
        return document
    }

    /// Writes `directory/config.toml` from the v1 files when it does not exist yet. Returns what
    /// it wrote, or nil when config.toml already exists or there are no v1 files.
    @discardableResult
    public func run(in directory: URL) throws -> ConfigDocument? {
        let destination = directory.appendingPathComponent("config.toml")
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT else { return nil }
        guard let legacy = try Self.readLegacy(from: directory) else { return nil }
        let document = try document(from: legacy)
        try ConfigFile.write(document.data, to: destination)
        return document
    }

    static let heading = """
    # Frog settings. Keys before the first [table] are Frog's own; each table belongs to a plugin.
    # Migrated from config and config.json, which are kept. Format: docs/config-format.md

    """

    // MARK: Core and plugins

    /// The v2 ID of each v1 feature: kebab-case, with the features that were renamed on the way.
    public static func pluginID(for feature: FeatureID) -> String {
        switch feature {
        case .applicationShortcuts: "shortcuts"
        case .scratchpad: "notes"
        case .usage: "llm-usage"
        case .menuBar: "hidden-bar"
        case .cleaner: "app-cleaner"
        default: ConfigKeys.kebab(feature.rawValue)
        }
    }

    /// `[plugins]`: every v1 feature, on or off as the old files had it, old defaults included.
    public static func pluginsTable(from legacy: Configuration) -> ConfigTable {
        var table = ConfigTable()
        for feature in FeatureID.allCases { table[pluginID(for: feature)] = .bool(legacy.preferences.featureEnabled(feature)) }
        return table
    }

    /// The core keys: appearance, history, model unloading, agent access and the sidebar.
    public static func coreTable(from legacy: Configuration) -> ConfigTable {
        let preferences = legacy.preferences
        let appearance = preferences.appearance ?? AppearancePreferences()
        let toolkit = preferences.toolkitSettings
        func ids<S: Sequence<String>>(_ features: S, sorted: Bool) -> ConfigValue {
            let ids = features.compactMap { FeatureID(rawValue: $0).map(pluginID(for:)) }
            return .array((sorted ? ids.sorted() : ids).map(ConfigValue.string))
        }
        var table: ConfigTable = [
            "appearance": .string((appearance.mode ?? .system).rawValue),
            "theme": .string(appearance.effectiveTheme.rawValue),
        ]
        if let useThemeAccent = appearance.useThemeAccent { table["theme-accent"] = .bool(useThemeAccent) }
        table["accent"] = .string("#" + appearance.accentHex)
        table["transparency"] = .float(appearance.transparency)
        table["popup-transparency"] = .float(appearance.popupTransparency ?? 0)
        if let glow = appearance.glow { table["glow"] = .string(glow.rawValue) }
        if let strength = appearance.glowStrength { table["glow-strength"] = .float(strength) }
        if let motion = appearance.glowMotion { table["glow-motion"] = .bool(motion) }
        table["history-enabled"] = .bool(preferences.historyEnabled)
        table["history-hide-text"] = .bool(preferences.hideHistoryText)
        table["history-limit"] = .integer(preferences.historyLimit)
        table["history-retention-days"] = .integer(preferences.historyRetentionDays)
        table["model-idle-seconds"] = .integer(preferences.workflowSettings.idleUnloadSeconds)
        table["agent-access"] = .bool(toolkit.agentAccess ?? false)
        table["hidden-sidebar-items"] = ids(toolkit.hiddenSidebarItems, sorted: true)
        table["pinned-sidebar-items"] = ids(toolkit.pinnedSidebarItems, sorted: true)
        table["sidebar-order"] = ids(toolkit.sidebarOrder, sorted: false)
        var palette = ConfigTable()
        for (mode, colors) in [("light", appearance.lightPalette), ("dark", appearance.darkPalette)] {
            guard let colors, !colors.isEmpty else { continue }
            var roles = ConfigTable()
            for role in AppearancePreferences.paletteKeys { if let hex = colors[role] { roles[role] = .string("#" + hex) } }
            palette[mode] = .table(roles)
        }
        if !palette.isEmpty { table["palette"] = .table(palette) }
        return table
    }
}
