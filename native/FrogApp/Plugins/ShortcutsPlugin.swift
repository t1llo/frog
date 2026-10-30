import AppKit
import Combine
import SwiftUI
import FrogCore

/// One global shortcut: a key and the plugin action it runs, with that action's parameters.
struct ShortcutBinding: ConfigSection, Hashable {
    var key: Shortcut?
    var action = ""
    var with: [String: String] = [:]

    init() {}
    init(key: Shortcut?, action: String, with: [String: String] = [:]) { self.key = key; self.action = action; self.with = with }

    static let openApp = "shortcuts.open-app", system = "shortcuts.system"
    var app: String? { action == Self.openApp ? with["app"] : nil }
}

/// `[shortcuts]` in config.toml.
struct ShortcutsSettings: ConfigSection {
    /// Absent until Frog first wrote the table from the app shortcuts made before it.
    var bindings: [ShortcutBinding]?

    static let comments = [
        "": "Shortcuts: keys that open apps and run Frog actions. `frog run shortcuts.list` shows them.",
        "bindings": "key, the action to run (`frog actions` lists them) and its parameters in `with`."
    ]

    /// The app and Mac command shortcuts the rules held before this table existed.
    static func seed(from rules: [Rule]) -> [ShortcutBinding] {
        rules.compactMap { rule in
            guard rule.enabled, let hotkey = rule.hotkey, let key = try? Shortcut(hotkey) else { return nil }
            switch rule.category {
            case .application:
                guard let app = rule.action?.applicationBundleID ?? rule.action?.applicationPath else { return nil }
                return ShortcutBinding(key: key, action: ShortcutBinding.openApp, with: ["app": app])
            case .system:
                guard let command = rule.action?.systemAction else { return nil }
                return ShortcutBinding(key: key, action: ShortcutBinding.system, with: ["command": command.rawValue])
            default: return nil
            }
        }
    }
}

/// Global shortcuts that open apps or run any plugin action. They are registered while the plugin runs and let
/// go while a shortcut is being recorded elsewhere in Frog.
final class ShortcutsPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "shortcuts", name: "Shortcuts", symbol: "command", tint: .blue, category: .navigate,
                                 summary: "Keys that open apps and run actions", enabledByDefault: true, recommended: true)

    private(set) var bindings: [ShortcutBinding] = []
    /// Why a binding's key could not be registered, by key.
    private(set) var issues: [Shortcut: String] = [:]
    private let hotkeys = HotkeyManager()
    private var registered: [UUID: ShortcutBinding] = [:]
    private var recording: AnyCancellable?
    private var running: Task<Void, Never>?
    private lazy var systemRows = SystemCommandRows { [weak self] in self?.runSystem($0) }

    func start() async {
        load()
        recording = model.$isRecordingShortcut.dropFirst().removeDuplicates().sink { [weak self] recording in
            if recording { self?.hotkeys.unregister() } else { self?.register() }
        }
        register()
    }

    func stop() async {
        recording = nil
        hotkeys.unregister(); registered = [:]
        running?.cancel(); running = nil
    }

    func settingsChanged() {
        let previous = bindings
        load()
        if bindings != previous { register() }
    }

    var commandBarRows: [any CommandBarRowProviding] { [systemRows] }

    // MARK: Bindings

    private func load() {
        var settings = context.settings(ShortcutsSettings.self)
        if settings.bindings == nil {
            settings.bindings = ShortcutsSettings.seed(from: model.configuration.rules)
            do { try context.save(settings) } catch { context.report(error) }
        }
        bindings = settings.bindings ?? []
    }

    /// Replaces the bindings and saves them. A key bound twice keeps its last binding.
    func save(_ next: [ShortcutBinding]) throws {
        var seen = Set<Shortcut>()
        let unique = next.reversed().filter { binding in binding.key.map { seen.insert($0).inserted } ?? true }.reversed()
        var settings = ShortcutsSettings()
        settings.bindings = Array(unique)
        try context.save(settings)
        bindings = settings.bindings ?? []
        register()
        model.objectWillChange.send()
    }

    /// Binds `key` to `action`, replacing what the key ran before.
    func bind(_ key: Shortcut, to action: String, with values: [String: String] = [:]) throws {
        guard let found = context.host.action(action) else { throw ActionError.unknown(action) }
        guard found.surfaces.contains(.shortcut) else { throw ActionError.failed("\(found.title) cannot run from a shortcut.") }
        if let missing = found.parameters.first(where: { $0.required && (values[$0.name] ?? "").isEmpty }) { throw ActionError.missing(missing.name) }
        if let unknown = values.keys.first(where: { name in !found.parameters.contains { $0.name == name } }) {
            throw ActionError.failed("\(action) has no parameter “\(unknown)”.")
        }
        if let issue = HotkeyManager.validationError(key.hotkey) { throw ActionError.failed(issue) }
        try save(bindings.filter { $0.key != key } + [ShortcutBinding(key: key, action: action, with: values)])
    }

    private func register() {
        guard model.registerShortcuts, !model.isRecordingShortcut else { return }
        registered = [:]
        var rules: [Rule] = []
        for binding in bindings {
            guard let key = binding.key else { continue }
            let rule = Rule(id: UUID(), name: binding.action, hotkey: key.hotkey)
            rules.append(rule); registered[rule.id] = binding
        }
        let errors = hotkeys.register(rules: rules, onPress: { [weak self] id in self?.trigger(id) }) { _ in }
        issues = Dictionary(errors.compactMap { id, issue in registered[id]?.key.map { ($0, issue) } }, uniquingKeysWith: { first, _ in first })
    }

    private func trigger(_ id: UUID) {
        guard let binding = registered[id] else { return }
        running?.cancel()
        running = Task { [weak self, host = context.host] in
            do { _ = try await host.run(binding.action, ActionInput(values: binding.with, source: .shortcut)) }
            catch is CancellationError {}
            catch { self?.context.report(error) }
        }
    }

    private func runSystem(_ action: SystemAction) { model.runSystemAction(action) }

    /// What a binding shows: the app's or the action's name.
    func title(of binding: ShortcutBinding) -> String {
        if let app = binding.app { return Self.applicationURL(app).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? app }
        if binding.action == ShortcutBinding.system, let command = binding.with["command"].flatMap(SystemAction.init(rawValue:)) { return command.title }
        return context.host.action(binding.action)?.title ?? binding.action
    }

    /// An app by path, bundle ID or name.
    static func applicationURL(_ app: String) -> URL? {
        if app.hasPrefix("/") { return FileManager.default.fileExists(atPath: app) ? URL(fileURLWithPath: app) : nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) { return url }
        let name = app.hasSuffix(".app") ? app : app + ".app"
        return ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"].lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Page and actions

    func page() -> AnyView? { legacyPage(ShortcutsSettingsView(plugin: self)) }

    struct Listed: Encodable {
        let key: String?, action: String, with: [String: String], title: String
    }

    var actions: [PluginAction] {
        [
            PluginAction(id: ShortcutBinding.openApp, title: "Open an app", symbol: "app",
                         parameters: [ActionParameter(name: "app", required: true, help: "The app's name, bundle ID or path")],
                         surfaces: [.agent, .shortcut]) { input in
                let name = try input.required("app")
                guard let url = Self.applicationURL(name) else { throw ActionError.failed("No app named \(name).") }
                try await ApplicationLauncher().open(url)
                return .done("Opened \(url.deletingPathExtension().lastPathComponent).")
            },
            PluginAction(id: ShortcutBinding.system, title: "Run a Mac command", symbol: "command",
                         parameters: [ActionParameter(name: "command", kind: .choice(SystemAction.allCases.map(\.rawValue)), required: true,
                                                      help: "Such as lockScreen or openDownloads")],
                         surfaces: [.agent, .shortcut]) { [weak self] input in
                guard let command = SystemAction(rawValue: try input.required("command")) else { throw ActionError.invalid("command", "a Mac command") }
                self?.runSystem(command)
                return .done("\(command.title).")
            },
            PluginAction(id: "shortcuts.list", title: "List shortcuts", symbol: "list.bullet", surfaces: [.agent]) { [weak self] _ in
                guard let self else { return ActionResult([Listed](), text: "") }
                let listed = self.bindings.map { Listed(key: $0.key?.description, action: $0.action, with: $0.with, title: self.title(of: $0)) }
                let text = listed.isEmpty ? "No shortcuts." : listed.map { "\($0.key ?? "(no key)")  \($0.title)  [\($0.action)]" }.joined(separator: "\n")
                return ActionResult(listed, text: text)
            },
            PluginAction(id: "shortcuts.bind", title: "Bind a shortcut", symbol: "keyboard",
                         parameters: [ActionParameter(name: "key", required: true, help: "Such as ctrl+alt+t"),
                                      ActionParameter(name: "action", required: true, help: "An action ID from `frog actions`"),
                                      ActionParameter(name: "with", help: "Its parameters: name=value, comma separated")],
                         surfaces: [.agent]) { [weak self] input in
                guard let self else { throw ActionError.failed("Shortcuts is off.") }
                let key = try Self.shortcut(try input.required("key"))
                let values = try Self.parameters(input.value("with") ?? "")
                try self.bind(key, to: try input.required("action"), with: values)
                return .done("\(key) runs \(try input.required("action")).")
            },
            PluginAction(id: "shortcuts.unbind", title: "Remove a shortcut", symbol: "keyboard.badge.ellipsis",
                         parameters: [ActionParameter(name: "key", required: true, help: "Such as ctrl+alt+t")],
                         surfaces: [.agent]) { [weak self] input in
                guard let self else { throw ActionError.failed("Shortcuts is off.") }
                let key = try Self.shortcut(try input.required("key"))
                guard self.bindings.contains(where: { $0.key == key }) else { throw ActionError.failed("Nothing is bound to \(key).") }
                try self.save(self.bindings.filter { $0.key != key })
                return .done("Removed \(key).")
            }
        ]
    }

    static func shortcut(_ text: String) throws -> Shortcut {
        do { return try Shortcut(text) } catch { throw ActionError.invalid("key", "a shortcut such as ctrl+alt+t") }
    }

    /// `app=Safari,mode=new` into its values.
    static func parameters(_ text: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { throw ActionError.invalid("with", "name=value pairs, comma separated") }
            values[parts[0]] = parts[1]
        }
        return values
    }
}
