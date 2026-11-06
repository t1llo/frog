import AppKit
import Combine
import FrogCore
import SwiftUI
@preconcurrency import UserNotifications

/// What a plugin can do beyond its page, each behind its own permission: a menu-bar item with a popup, global
/// shortcuts, running in the background with Mac events, settings, picked folders, the selection and Frog's own
/// actions. Everything here starts when the plugin runs and goes when it is turned off or removed.
extension PluginRuntime {
    // MARK: Keeping in step

    /// Brings menu-bar items, shortcuts, background pages and Mac event observers in line with the plugins that run.
    func syncCapabilities() {
        let runningItems = enabled ? items.filter(\.runs) : []
        let byID = Dictionary(runningItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Menu-bar items: one per running plugin that has one, rebuilt when its manifest changed.
        for (id, item) in statusItems where byID[id].map({ Self.allows($0, .menubar) && $0.manifest?.menubar == item.menubar }) != true {
            item.stop()
            statusItems[id] = nil
            closePopup(id)
        }
        for item in runningItems where statusItems[item.id] == nil && Self.allows(item, .menubar) {
            guard let manifest = item.manifest, let menubar = manifest.menubar else { continue }
            statusItems[item.id] = PluginStatusItem(id: item.id, name: manifest.name, symbol: item.symbol, menubar: menubar, runtime: self)
        }
        for id in popups.keys where byID[id] == nil { closePopup(id) }

        syncShortcuts(runningItems)

        // Background pages load at once and stay; one whose plugin stopped is unloaded by `refresh`.
        let background = runningItems.filter { Self.allows($0, .background) }
        for item in background where hosts[item.id] == nil {
            let id = item.id
            Task { @MainActor [weak self] in
                do { _ = try await self?.host(for: id) } catch { self?.log(id, level: "error", "Could not start in the background: \(error.localizedDescription)") }
            }
        }
        observeMac(background.isEmpty ? [] : background)
    }

    /// Ends every capability, as when Plugins turns off.
    func stopCapabilities() {
        for item in statusItems.values { item.stop() }
        statusItems = [:]
        for id in Array(popups.keys) { closePopup(id) }
        syncShortcuts([])
        observeMac([])
    }

    /// Forgets one plugin's capabilities so the next sync builds them from its current manifest.
    func dropCapabilities(_ id: String) {
        statusItems[id]?.stop()
        statusItems[id] = nil
        closePopup(id)
    }

    /// Whether the plugin asks for `permission` and the user approved it.
    static func allows(_ item: PluginItem, _ permission: PluginPermission) -> Bool {
        (item.manifest?.permissions.contains(permission) ?? false) && (item.record.approved?.permissions.contains(permission) ?? false)
    }

    /// A background plugin's page stays loaded while the plugin runs.
    func keepsRunning(_ id: String) -> Bool {
        guard let item = item(id), item.runs else { return false }
        return Self.allows(item, .background)
    }

    /// Sends an event to every page of the plugin: its page and its popup.
    func broadcast(_ id: String, _ event: String, _ value: Any? = nil) {
        hosts[id]?.emit(event, value)
        popups[id]?.emit(event, value)
    }

    // MARK: Menu bar

    /// The popup's page, loaded on first open and kept while the plugin runs, so it opens at once the next time.
    func popupHost(for id: String) async throws -> PluginWebHost {
        if let popup = popups[id] { return popup }
        guard let item = item(id), item.runs, Self.allows(item, .menubar), item.manifest?.menubar?.popup != nil else {
            throw FrogError.message("The plugin has no popup that can open now.")
        }
        let rules = try await contentRuleList()
        if let popup = popups[id] { return popup }
        let package = try store.package(id)
        var inspectable = false
        if case .folder = item.record.source { inspectable = true }
        let popup = PluginWebHost(package: package, contentRules: rules, runtime: self, inspectable: inspectable, surface: .popup)
        popups[id] = popup
        popup.load()
        return popup
    }

    func closePopup(_ id: String) {
        statusItems[id]?.closePopup()
        popups[id]?.stop()
        popups[id] = nil
    }

    /// The menu-bar item was clicked: run its action, open its popup or show the page.
    func menuBarClicked(_ id: String) {
        guard let item = item(id), item.runs, let manifest = item.manifest, let menubar = manifest.menubar else { return }
        if let action = menubar.action {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hosts[id]?.lastCommand = Date()
                do { _ = try await self.perform(action, of: id, values: [:], text: nil) }
                catch { self.log(id, level: "error", error.localizedDescription); self.report(error) }
            }
        } else if menubar.popup == nil, manifest.entry != nil {
            openPage(id)
        }
    }

    // MARK: Shortcuts

    static func shortcutKey(_ plugin: String, _ action: String) -> String { "\(plugin)/\(action)" }

    /// The key that runs the action: the user's choice, or the plugin's default. Nil when it has none.
    func shortcut(_ plugin: String, action: String) -> Shortcut? {
        guard let manifestAction = item(plugin)?.manifest?.actions.first(where: { $0.id == action }) else { return nil }
        if let json = try? shortcutChoices(plugin).get(action),
           let text = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) as? String {
            return text.isEmpty ? nil : try? Shortcut(text)
        }
        return manifestAction.shortcut.flatMap { try? Shortcut($0) }
    }

    /// Gives the action another key, or none. A key Frog uses elsewhere is refused.
    func setShortcut(_ plugin: String, action: String, to shortcut: Shortcut?) throws {
        guard let item = item(plugin), item.manifest?.actions.contains(where: { $0.id == action }) == true else {
            throw FrogError.message("The plugin has no action “\(action)”.")
        }
        if let shortcut {
            if let issue = HotkeyManager.validationError(shortcut.hotkey) { throw FrogError.message(issue) }
            try checkShortcut(shortcut.hotkey, Set(shortcutIDs.values))
            // The key moves here from another of the plugin's actions.
            for other in item.manifest?.actions ?? [] where other.id != action && self.shortcut(plugin, action: other.id) == shortcut {
                try shortcutChoices(plugin).set(other.id, json: "\"\"")
            }
        }
        let text = shortcut?.description ?? ""
        let json = String(decoding: try JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
        try shortcutChoices(plugin).set(action, json: json)
        syncShortcuts(enabled ? items.filter(\.runs) : [])
    }

    private func shortcutChoices(_ id: String) throws -> PluginStorage {
        PluginStorage(folder: try dataFolder(id), name: "shortcuts.json")
    }

    func syncShortcuts(_ runningItems: [PluginItem]) {
        var wanted: [UUID: (name: String, hotkey: Hotkey, action: () -> Void)] = [:]
        var keys: [UUID: String] = [:]
        for item in runningItems where Self.allows(item, .hotkeys) {
            guard let manifest = item.manifest else { continue }
            for action in manifest.actions {
                guard let shortcut = shortcut(item.id, action: action.id) else { continue }
                let key = Self.shortcutKey(item.id, action.id)
                let uuid = shortcutIDs[key] ?? UUID()
                shortcutIDs[key] = uuid
                keys[uuid] = key
                let plugin = item.id, actionID = action.id
                wanted[uuid] = ("\(manifest.name): \(action.title)", shortcut.hotkey, { [weak self] in self?.shortcutPressed(plugin, actionID) })
            }
        }
        guard !(wanted.isEmpty && registeredShortcuts.isEmpty) else { return }
        let errors = registerShortcuts(registeredShortcuts, wanted)
        registeredShortcuts = Set(wanted.keys)
        shortcutIssues = Dictionary(errors.compactMap { uuid, error in keys[uuid].map { ($0, error) } }, uniquingKeysWith: { first, _ in first })
    }

    private func shortcutPressed(_ plugin: String, _ action: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A key the user pressed counts as a command: the page may show itself, write the clipboard or read the selection.
            self.hosts[plugin]?.lastCommand = Date()
            do { _ = try await self.perform(action, of: plugin, values: [:], text: nil) }
            catch { self.log(plugin, level: "error", error.localizedDescription); self.report(error) }
        }
    }

    // MARK: Background and Mac events

    /// Watches the Mac for the background plugins: wake, sleep, the screen locking, the frontmost app and the
    /// clipboard, the last only for plugins that may read it. Nothing is watched without a background plugin.
    func observeMac(_ background: [PluginItem]) {
        let wantsClipboard = background.contains { Self.allows($0, .clipboardRead) }
        if background.isEmpty {
            for observer in macObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            for observer in screenObservers { DistributedNotificationCenter.default().removeObserver(observer) }
            macObservers = []; screenObservers = []
        } else if macObservers.isEmpty {
            let workspace = NSWorkspace.shared.notificationCenter
            func observe(_ name: Notification.Name, _ event: String) -> NSObjectProtocol {
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.backgroundEvent(event, nil) }
                }
            }
            macObservers = [observe(NSWorkspace.didWakeNotification, "wake"), observe(NSWorkspace.willSleepNotification, "sleep"),
                            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                                let value: [String: String] = ["name": app?.localizedName ?? "", "bundleId": app?.bundleIdentifier ?? ""]
                                MainActor.assumeIsolated { self?.backgroundEvent("app", value) }
                            }]
            let distributed = DistributedNotificationCenter.default()
            screenObservers = [("com.apple.screenIsLocked", "lock"), ("com.apple.screenIsUnlocked", "unlock")].map { name, event in
                distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.backgroundEvent(event, nil) }
                }
            }
        }
        if wantsClipboard, clipboardWatch == nil {
            clipboardCount = pasteboard.changeCount
            clipboardWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkClipboard() }
            }
        } else if !wantsClipboard {
            clipboardWatch?.invalidate()
            clipboardWatch = nil
        }
    }

    private func backgroundEvent(_ event: String, _ value: Any?) {
        for item in items where item.runs && Self.allows(item, .background) { hosts[item.id]?.emit(event, value) }
    }

    private func checkClipboard() {
        let count = pasteboard.changeCount
        guard count != clipboardCount else { return }
        clipboardCount = count
        // Text marked as sensitive, such as a password manager's, is not announced.
        guard !pasteboard.holdsSensitiveText else { return }
        for item in items where item.runs && Self.allows(item, .background) && Self.allows(item, .clipboardRead) {
            guard let host = hosts[item.id] else { continue }
            host.clipboardChangedAt = Date()
            host.emit("clipboard")
        }
    }

    // MARK: Settings

    private func settingsStore(_ id: String) throws -> PluginStorage {
        PluginStorage(folder: try dataFolder(id), name: "settings.json")
    }

    func dataFolder(_ id: String) throws -> URL {
        let folder = store.dataFolder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// The setting's value: what the user or the plugin chose, or its default. A secret reads from the Keychain.
    func settingValue(_ id: String, _ setting: PluginSetting) throws -> PluginSettingValue? {
        if setting.type == .secret { return try secrets.read(setting.key, plugin: id).map(PluginSettingValue.text) }
        guard let json = try settingsStore(id).get(setting.key),
              let value = try? JSONDecoder().decode(PluginSettingValue.self, from: Data(json.utf8)),
              let accepted = try? setting.accept(value) else { return setting.initial }
        return accepted
    }

    /// Keeps a new value, a secret in the Keychain, and tells the plugin's pages. Nil puts the default back.
    func setSetting(_ id: String, _ key: String, _ value: PluginSettingValue?) throws {
        guard let setting = item(id)?.manifest?.settings.first(where: { $0.key == key }) else {
            throw FrogError.message("The plugin has no setting “\(key)” in plugin.json.")
        }
        let accepted = try value.map(setting.accept)
        if setting.type == .secret {
            if case .text(let text)? = accepted, !text.isEmpty { try secrets.save(text, key: key, plugin: id) }
            else { try secrets.delete(key, plugin: id) }
            broadcast(id, "settings", ["key": key])
        } else {
            let json = try accepted.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            try settingsStore(id).set(key, json: json)
            broadcast(id, "settings", ["key": key, "value": (try settingValue(id, setting))?.json ?? NSNull()])
        }
        objectWillChange.send()
    }

    // MARK: Folders

    func folders(_ id: String) throws -> PluginFolders { PluginFolders(folder: try dataFolder(id)) }

    /// Forgets a folder the user gave the plugin.
    func forgetFolder(_ id: String, _ folder: String) throws {
        try folders(id).remove(folder)
        objectWillChange.send()
    }

    // MARK: Bridge calls

    /// Calls for the capabilities in this file; nil when `name` is none of them.
    func handleCapability(_ name: String, _ arguments: [String: Any], from host: PluginWebHost, approved: PluginGrant,
                          require: (PluginPermission) throws -> Void) async throws -> Any?? {
        let id = host.id
        func text(_ key: String, maximum: Int, required: Bool = true) throws -> String? {
            guard let value = arguments[key] as? String else {
                if required { throw FrogError.message("\(name) needs “\(key)”.") }
                return nil
            }
            guard value.utf8.count <= maximum else { throw FrogError.message("“\(key)” is longer than \(max(1, maximum / 1024)) KB.") }
            return value
        }
        func setting(_ key: String) throws -> PluginSetting {
            guard let setting = host.manifest.settings.first(where: { $0.key == key }) else {
                throw FrogError.message("The plugin has no setting “\(key)” in plugin.json.")
            }
            return setting
        }

        switch name {
        case "settings.get":
            let found = try setting(try text("key", maximum: 100)!)
            return .some(try settingValue(id, found)?.json)
        case "settings.all":
            var values: [String: Any] = [:]
            for found in host.manifest.settings where found.type != .secret {
                values[found.key] = try settingValue(id, found)?.json ?? NSNull()
            }
            return .some(values)
        case "settings.set":
            let key = try text("key", maximum: 100)!
            _ = try setting(key)
            let raw = arguments["value"]
            let value: PluginSettingValue?
            if raw == nil || raw is NSNull { value = nil }
            else if let parsed = raw.flatMap(PluginSettingValue.init(json:)) { value = parsed }
            else { throw FrogError.message("A setting's value is text, a whole number, true or false.") }
            try setSetting(id, key, value)
            return .some(nil)

        case "selection.read":
            try require(.selection)
            guard host.runningEffect != nil || host.commandedRecently else {
                throw FrogError.message("A plugin reads the selection only while one of its actions runs or right after a command or shortcut.")
            }
            let captured = try await captureSelection()
            host.capturedSelection = (captured, Date())
            return .some(["text": captured.text, "app": captured.applicationName ?? NSNull()] as [String: Any])
        case "selection.replace":
            try require(.selection)
            let replacement = try text("text", maximum: 1024 * 1024)!
            guard let captured = host.capturedSelection, Date().timeIntervalSince(captured.at) < 120 else {
                throw FrogError.message("Read the selection with frog.selection.read() first; it can be replaced for two minutes after.")
            }
            host.capturedSelection = nil
            try await captured.selection.replace(with: replacement)
            return .some(nil)

        case "actions.run":
            try require(.frogActions)
            let action = try text("id", maximum: 200)!
            guard PluginUses.allows(action, patterns: host.manifest.uses.filter(approved.uses.contains)) else {
                throw FrogError.message("“\(action)” is not in the plugin's “uses” in plugin.json, or the user has not approved it.")
            }
            let values = (arguments["params"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            guard values.count <= 30, values.values.allSatisfy({ $0.utf8.count <= 100_000 }) else {
                throw FrogError.message("An action takes at most 30 parameters of 100 KB each.")
            }
            let input = try text("text", maximum: 1024 * 1024, required: false)
            let answer = try await limited(id, "action", maximum: 2) { try await self.runFrogAction(action, values, input) }
            let parsed = try? JSONSerialization.jsonObject(with: Data(answer.json.utf8), options: .fragmentsAllowed)
            return .some(["text": answer.text, "json": parsed ?? NSNull()] as [String: Any])

        case "files.pick":
            try require(.files)
            guard host.isShowing else { throw FrogError.message("A plugin asks for a folder only while its page or popup is open.") }
            guard let url = await pickFolder(host.manifest.name) else { return .some(nil) }
            let folder = try folders(id).add(url)
            objectWillChange.send()
            return .some(["id": folder.id, "name": folder.name])
        case "files.folders":
            try require(.files)
            return .some(try folders(id).list().map { ["id": $0.id, "name": $0.name] })
        case "files.list":
            try require(.files)
            let url = try folders(id).resolve(try text("folder", maximum: 20)!, try text("path", maximum: 2_000)!)
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                .prefix(2_000).map { entry -> [String: Any] in
                    let values = try? entry.resourceValues(forKeys: Set(keys))
                    return ["name": entry.lastPathComponent, "directory": values?.isDirectory ?? false, "size": values?.fileSize ?? 0,
                            "modified": (values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000]
                }
            return .some(entries.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") })
        case "files.read":
            try require(.files)
            let url = try folders(id).resolve(try text("folder", maximum: 20)!, try text("path", maximum: 2_000)!)
            let data = try PluginPackage.readFile(url, maximumBytes: 10 * 1024 * 1024)
            if arguments["as"] as? String == "base64" { return .some(data.base64EncodedString()) }
            guard let string = String(data: data, encoding: .utf8) else { throw FrogError.message("The file is not text; read it with { as: \"base64\" }.") }
            return .some(string)
        case "files.write":
            try require(.files)
            let url = try folders(id).resolve(try text("folder", maximum: 20)!, try text("path", maximum: 2_000)!)
            let raw = try text("data", maximum: 14 * 1024 * 1024)!
            let data: Data
            if arguments["as"] as? String == "base64" {
                guard let decoded = Data(base64Encoded: raw) else { throw FrogError.message("The data is not Base64.") }
                data = decoded
            } else { data = Data(raw.utf8) }
            guard data.count <= 10 * 1024 * 1024 else { throw FrogError.message("A plugin writes files of at most 10 MB.") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return .some(nil)
        case "files.trash":
            try require(.files)
            let path = try text("path", maximum: 2_000)!
            guard !path.isEmpty else { throw FrogError.message("A plugin cannot move a whole folder it was given to the Trash.") }
            let url = try folders(id).resolve(try text("folder", maximum: 20)!, path)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return .some(nil)

        case "menubar.set":
            try require(.menubar)
            guard let statusItem = statusItems[id] else { throw FrogError.message("The plugin has no menu-bar item in plugin.json.") }
            let title = try text("title", maximum: 200, required: false)
            if let title, title.count > 24 { throw FrogError.message("A menu-bar title has at most 24 characters.") }
            let symbol = try text("symbol", maximum: 60, required: false)
            if let symbol, !PluginManifest.isValidSymbol(symbol) { throw FrogError.message("“\(symbol)” is not an SF Symbol name.") }
            statusItem.update(title: title, symbol: symbol, tooltip: try text("tooltip", maximum: 400, required: false))
            return .some(nil)
        case "menubar.resize":
            try require(.menubar)
            guard host.surface == .popup else { throw FrogError.message("Only the popup resizes.") }
            let height = (arguments["height"] as? NSNumber)?.intValue ?? PluginMenuBar.defaultHeight
            statusItems[id]?.resize(height: min(max(height, PluginMenuBar.heights.lowerBound), PluginMenuBar.heights.upperBound))
            return .some(nil)
        case "menubar.close":
            try require(.menubar)
            statusItems[id]?.closePopup()
            return .some(nil)

        default:
            return nil
        }
    }

    /// Notification buttons: a category per set of buttons, with the plugin's tag in the user info.
    static func notificationCategory(_ id: String, actions: [(id: String, title: String)]) -> UNNotificationCategory? {
        guard !actions.isEmpty else { return nil }
        let identifier = "plugin.\(id)/" + actions.map(\.id).joined(separator: ",")
        return UNNotificationCategory(identifier: identifier,
                                      actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) },
                                      intentIdentifiers: [])
    }

    /// The user clicked a plugin's notification or one of its buttons.
    func notificationAnswered(_ action: String, _ info: [String: String]) {
        guard let id = info["plugin"], let item = item(id), item.runs else { return }
        let tag = info["tag"] ?? ""
        let clicked = action == UNNotificationDefaultActionIdentifier
        if action == UNNotificationDismissActionIdentifier { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The page hears the answer, loaded for it if need be; a button counts as a command the user gave.
            if let host = try? await self.host(for: id) {
                host.lastCommand = Date()
                host.emit("notification", ["id": tag, "action": clicked ? "open" : action])
            }
            if clicked, item.hasPage { self.openPage(id) }
        }
    }
}

/// A plugin's own menu-bar item: its symbol and title, and a click that opens its popup, runs its action or shows
/// its page.
@MainActor final class PluginStatusItem: NSObject {
    let id: String
    let menubar: PluginMenuBar
    private let name: String
    private let defaultSymbol: String
    private var item: NSStatusItem?
    private let presenter: StatusItemPopup
    private weak var runtime: PluginRuntime?
    private let size = PluginPopupSize()

    init(id: String, name: String, symbol: String, menubar: PluginMenuBar, runtime: PluginRuntime) {
        self.id = id; self.name = name; self.menubar = menubar; self.runtime = runtime
        defaultSymbol = menubar.symbol ?? symbol
        presenter = StatusItemPopup(name: "plugin.\(id)")
        super.init()
        size.height = CGFloat(menubar.popupHeight)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Frog.Plugin.\(id)"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.imagePosition = .imageLeading
        self.item = item
        presenter.onClose = { [weak self] in
            guard let self, let popup = self.runtime?.popups[self.id] else { return }
            popup.isShowing = false
        }
        update(title: menubar.title, symbol: nil, tooltip: nil)
    }

    func update(title: String?, symbol: String?, tooltip: String?) {
        guard let button = item?.button else { return }
        let image = NSImage(systemSymbolName: PluginSymbol.name(symbol ?? currentSymbol ?? defaultSymbol), accessibilityDescription: name)
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: name)
        image?.isTemplate = true
        button.image = image
        if let symbol { currentSymbol = symbol }
        if let title { button.title = title.isEmpty ? "" : " " + title }
        button.toolTip = tooltip ?? button.toolTip ?? name
        button.setAccessibilityLabel(button.title.isEmpty ? name : "\(name), \(button.title)")
    }
    private var currentSymbol: String?

    @objc private func clicked() {
        guard let runtime, let button = item?.button else { return }
        guard menubar.popup != nil else { runtime.menuBarClicked(id); return }
        if presenter.isShown { presenter.close(); return }
        Task { @MainActor [weak self] in
            guard let self, let runtime = self.runtime else { return }
            do {
                let popup = try await runtime.popupHost(for: self.id)
                let view = PluginPopupView(name: self.name, symbol: self.defaultSymbol, width: CGFloat(self.menubar.popupWidth), size: self.size,
                                           host: popup, hasPage: runtime.item(self.id)?.hasPage == true) { [weak self] in
                    guard let self else { return }
                    self.presenter.close()
                    self.runtime?.openPage(self.id)
                }
                self.presenter.show(NSHostingView(rootView: view), relativeTo: button)
                popup.isShowing = true
                popup.refreshTheme()
            } catch {
                runtime.log(self.id, level: "error", error.localizedDescription)
                runtime.report(error)
            }
        }
    }

    func resize(height: Int) { size.height = CGFloat(height) }

    func closePopup() { presenter.close() }

    func stop() {
        presenter.close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
}

/// The popup's height, which the page may change while it is open.
@MainActor final class PluginPopupSize: ObservableObject {
    @Published var height: CGFloat = CGFloat(PluginMenuBar.defaultHeight)
}

/// A plugin's popup in Frog's popup style: its name and a way to its page above, its own page beneath.
struct PluginPopupView: View {
    let name: String
    let symbol: String
    let width: CGFloat
    @ObservedObject var size: PluginPopupSize
    let host: PluginWebHost
    let hasPage: Bool
    let openPage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FrogPopupHeader(symbol: PluginSymbol.name(symbol), tint: .purple, title: name) {
                if hasPage { IconAction(title: "Open \(name)", symbol: "arrow.up.forward.app", bordered: true, action: openPage) }
            }
            PluginWebContainer(host: host).frame(width: width - 2 * FrogStyle.panelCardInset, height: size.height)
        }
        .padding(FrogStyle.panelCardInset).frame(width: width).fixedSize(horizontal: false, vertical: true)
        .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
        .frogPanel()
        .background(MenuWindowSizing())
        .environment(\.locale, L10n.locale)
    }
}
