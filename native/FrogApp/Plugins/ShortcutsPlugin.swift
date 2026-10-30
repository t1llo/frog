import AppKit
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

    /// The app and Mac command shortcuts the rules held before this table existed. A rule that was off, or had
    /// no key Frog can write, keeps its app or command without a key.
    static func seed(from rules: [Rule]) -> [ShortcutBinding] {
        rules.compactMap { rule in
            let key = rule.enabled ? rule.hotkey.flatMap { try? Shortcut($0) } : nil
            switch rule.category {
            case .application:
                let path = rule.action?.applicationPath, bundleID = rule.action?.applicationBundleID
                guard let app = bundleID ?? path else { return nil }
                // The path tells apart copies that share a bundle ID, such as Xcode and Xcode-beta.
                var with = ["app": app]
                if bundleID != nil, let path { with["path"] = path }
                return ShortcutBinding(key: key, action: ShortcutBinding.openApp, with: with)
            case .system:
                guard let command = rule.action?.systemAction else { return nil }
                return ShortcutBinding(key: key, action: ShortcutBinding.system, with: ["command": command.rawValue])
            default: return nil
            }
        }
    }
}

/// Global shortcuts that open apps or run any plugin action. They register through Frog's own shortcuts, so
/// recording a shortcut anywhere lets them go and the end of recording brings back the latest bindings.
final class ShortcutsPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "shortcuts", name: "Shortcuts", symbol: "command", tint: .blue, category: .navigate,
                                 summary: "Keys that open apps and run actions", enabledByDefault: true, recommended: true)

    private(set) var bindings: [ShortcutBinding] = []
    /// The registration ID of each binding, in the same order; kept for a binding that did not change.
    private(set) var ids: [UUID] = []
    /// Set when `[shortcuts]` could not be read: the bindings are the last good ones, and nothing is saved over the table.
    private(set) var unreadable: String?
    /// The IDs this plugin has registered with Frog's shortcuts.
    private var registered = Set<UUID>()
    private var running: Task<Void, Never>?
    private lazy var systemRows = SystemCommandRows { [weak self] in self?.runSystem($0) }

    func start() async {
        load()
        register()
    }

    func stop() async {
        model.setPluginShortcuts(replacing: registered, with: [:]); registered = []
        running?.cancel(); running = nil
    }

    func settingsChanged() {
        let previous = bindings
        load()
        if bindings != previous { register() }
    }

    var commandBarRows: [any CommandBarRowProviding] { [systemRows] }

    // MARK: Bindings

    /// Why the binding at `index` could not be registered.
    func issue(at index: Int) -> String? { ids.indices.contains(index) ? model.hotkeyErrors[ids[index]] : nil }

    /// Reads `[shortcuts]`. Only a config.toml without `bindings` is seeded from the old app rules, and not while
    /// Frog's settings could not be loaded; a table that does not decode keeps the bindings Frog has.
    private func load() {
        let file = model.settingsFile
        if file.document.value(at: [info.id, "bindings"]) == nil {
            let seeded = ShortcutsSettings.seed(from: model.configuration.rules)
            if model.configurationLoaded {
                var settings = ShortcutsSettings(); settings.bindings = seeded
                do { try context.save(settings) } catch { context.report(error) }
            }
            adopt(seeded); unreadable = nil
            return
        }
        do {
            let result = try file.section(info.id, as: ShortcutsSettings.self)
            for warning in result.warnings { context.report(FrogError.message("config.toml line \(warning.line): \(warning.message)")) }
            adopt(result.value.bindings ?? []); unreadable = nil
        } catch {
            unreadable = "config.toml [shortcuts] could not be read, so the shortcuts are the last ones that could: \(error.localizedDescription)"
            context.report(error)
        }
    }

    private func adopt(_ next: [ShortcutBinding]) {
        var free = Dictionary(grouping: zip(bindings, ids), by: \.0).mapValues { $0.map(\.1) }
        ids = next.map { binding in
            guard var reused = free[binding], !reused.isEmpty else { return UUID() }
            let id = reused.removeFirst(); free[binding] = reused
            return id
        }
        bindings = next
    }

    /// Replaces the bindings and saves them. A key may be bound once; `setKey` moves a key from one binding to another.
    func save(_ next: [ShortcutBinding]) throws {
        let keys = next.compactMap(\.key)
        if let twice = keys.first(where: { key in keys.filter { $0 == key }.count > 1 }) {
            throw FrogError.message("\(HotkeyManager.display(twice.hotkey)) is bound twice.")
        }
        var settings = ShortcutsSettings()
        settings.bindings = next
        try context.save(settings)
        adopt(next); unreadable = nil
        register()
        model.objectWillChange.send()
    }

    /// Gives the binding at `index` a key. A key another binding had moves here and leaves that one without a
    /// key; a key something else in Frog uses is refused.
    func setKey(_ key: Shortcut?, at index: Int) throws {
        guard bindings.indices.contains(index) else { return }
        var next = bindings
        if let key {
            if let issue = HotkeyManager.validationError(key.hotkey) { throw FrogError.message(issue) }
            try model.checkShortcutFree(key.hotkey, except: Set(ids))
            for other in next.indices where other != index && next[other].key == key { next[other].key = nil }
        }
        next[index].key = key
        try save(next)
    }

    /// Binds `key` to `action`, replacing what the key ran before. Checks the action's parameters as running it would.
    func bind(_ key: Shortcut, to action: String, with values: [String: String] = [:]) throws {
        guard let found = context.host.action(action) else { throw ActionError.unknown(action) }
        guard found.surfaces.contains(.shortcut) else { throw ActionError.failed("\(found.title) cannot run from a shortcut.") }
        if let missing = found.parameters.first(where: { $0.required && (values[$0.name] ?? "").isEmpty }) { throw ActionError.missing(missing.name) }
        if let unknown = values.keys.first(where: { name in !found.parameters.contains { $0.name == name } }) {
            throw ActionError.failed("\(action) has no parameter “\(unknown)”.")
        }
        let input = ActionInput(values: values, source: .shortcut)
        for parameter in found.parameters where values[parameter.name] != nil {
            switch parameter.kind {
            case .integer: _ = try input.integer(parameter.name)
            case .boolean: _ = try input.boolean(parameter.name)
            case .choice(let options):
                guard options.contains(values[parameter.name]!) else { throw ActionError.invalid(parameter.name, "one of \(options.joined(separator: ", "))") }
            case .text: break
            }
        }
        if let issue = HotkeyManager.validationError(key.hotkey) { throw ActionError.failed(issue) }
        try model.checkShortcutFree(key.hotkey, except: Set(ids))
        try save(bindings.filter { $0.key != key } + [ShortcutBinding(key: key, action: action, with: values)])
    }

    private func register() {
        var shortcuts: [UUID: (name: String, hotkey: Hotkey, action: () -> Void)] = [:]
        for (binding, id) in zip(bindings, ids) {
            guard let key = binding.key else { continue }
            shortcuts[id] = (title(of: binding), key.hotkey, { [weak self] in self?.trigger(binding) })
        }
        model.setPluginShortcuts(replacing: registered, with: shortcuts)
        registered = Set(shortcuts.keys)
    }

    /// The app bindings with a key as app rules, for the window switcher's key badges.
    var applicationRules: [Rule] {
        zip(bindings, ids).compactMap { binding, id in
            guard let key = binding.key, let app = binding.app else { return nil }
            let url = Self.applicationURL(app, path: binding.with["path"])
            guard let bundleID = url.flatMap({ Bundle(url: $0)?.bundleIdentifier }) ?? (app.contains(".") && !app.hasPrefix("/") ? app : nil) else { return nil }
            var rule = Rule(id: id, name: title(of: binding), hotkey: key.hotkey)
            rule.action = RuleAction(category: .application)
            rule.action?.applicationBundleID = bundleID; rule.action?.applicationPath = url?.path
            return rule
        }
    }

    private func trigger(_ binding: ShortcutBinding) {
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
        if let app = binding.app { return Self.applicationURL(app, path: binding.with["path"]).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? app }
        if binding.action == ShortcutBinding.system, let command = binding.with["command"].flatMap(SystemAction.init(rawValue:)) { return command.title }
        return context.host.action(binding.action)?.title ?? binding.action
    }

    /// An app by path, bundle ID or name. With `path`, the copy there while it is still the app `app` names,
    /// otherwise the one the bundle ID finds: copies such as Xcode and Xcode-beta share an ID, and
    /// `ApplicationLauncher.launch` picks between them the same way.
    static func applicationURL(_ app: String, path: String? = nil) -> URL? {
        if let path, FileManager.default.fileExists(atPath: path) {
            let stored = URL(fileURLWithPath: path)
            if Bundle(url: stored)?.bundleIdentifier == app || app == path { return stored }
        }
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
                         parameters: [ActionParameter(name: "app", required: true, help: "The app's name, bundle ID or path"),
                                      ActionParameter(name: "path", help: "Which copy, when several share the bundle ID")],
                         surfaces: [.agent, .shortcut]) { input in
                let name = try input.required("app")
                guard let url = Self.applicationURL(name, path: input.value("path")) else { throw ActionError.failed("No app named \(name).") }
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
