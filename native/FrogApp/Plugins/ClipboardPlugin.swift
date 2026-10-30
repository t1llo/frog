import AppKit
import Combine
import SwiftUI
import FrogCore

/// `[clipboard]` in config.toml.
struct ClipboardSettings: ConfigSection {
    var shortcut = try! Shortcut("cmd+shift+v")
    var items = ClipboardHistoryStore.defaultCapacity

    static let comments = [
        "": "Clipboard: search and paste what you copied. Kept in memory only; passwords and keys never are.",
        "shortcut": "Opens clipboard history",
        "items": "How many copies to keep, 1 to 1000",
    ]

    /// With `items` in the range the store keeps, so the page shows what is kept.
    var clamped: ClipboardSettings {
        var settings = self
        settings.items = min(max(items, 1), ClipboardHistoryStore.maxCapacity)
        return settings
    }

    /// The table the first time the plugin runs: the shortcut set before config.toml existed.
    static func seed(from preferences: Preferences) -> ClipboardSettings {
        var settings = ClipboardSettings()
        if let hotkey = preferences.workflowSettings.clipboardHistoryHotkey, let shortcut = try? Shortcut(hotkey) { settings.shortcut = shortcut }
        return settings
    }
}

/// Clipboard history: one watch of the pasteboard while it is on, a panel opened by its shortcut, its page and
/// its actions. The store is Frog's shared clipboard service (Writing, Dictation and Phone write through it);
/// this plugin turns its history on and off.
final class ClipboardPlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "clipboard", name: "Clipboard", symbol: "doc.on.clipboard", tint: .orange, category: .navigate,
                                 summary: "Search and paste what you copied", recommended: true)
    static let shortcutID = UUID(uuidString: "E7A2D4E5-1CBC-41DB-8B3A-7114DC77943D")!

    let state = ClipboardPageState()
    private(set) var controller: ClipboardHistoryController?
    private var hotkeys: HotkeyManager?
    private var recordingObservation: AnyCancellable?
    private var warming: Task<Void, Never>?
    /// Why `[clipboard] shortcut` is not registered: another Frog shortcut uses it.
    private var shortcutClash: String?
    var store: ClipboardHistoryStore { model.clipboardHistoryStore }

    func start() async {
        seedSettingsIfNeeded()
        state.settings = context.settings(ClipboardSettings.self).clamped
        store.capacity = state.settings.items
        mirrorShortcut()
        let controller = ClipboardHistoryController(pasteboard: store.pasteboard, history: store)
        controller.onError = { [weak self] in self?.context.report($0) }
        controller.onSuccessfulPaste = { [weak model] in model?.statistics.recordToolUse(.clipboardPaste) }
        controller.configure(enabled: true, automaticallyPoll: model.runsLiveServices)
        self.controller = controller
        guard model.runsLiveServices else { return }
        registerShortcut()
        // The first open would otherwise build the panel and load SwiftUI for it while the keys are down.
        warming = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.controller?.prepare()
        }
        // A shortcut being recorded anywhere in Frog must reach the recorder, not open the panel.
        recordingObservation = model.$isRecordingShortcut.dropFirst().removeDuplicates().sink { [weak self] recording in
            guard let self else { return }
            if recording { self.controller?.cancel(); self.hotkeys?.unregister() } else { self.registerShortcut() }
        }
    }

    func stop() async {
        warming?.cancel(); warming = nil
        recordingObservation = nil
        hotkeys?.unregister(); hotkeys = nil
        controller?.stop(); controller = nil
        state.shortcutIssue = nil
    }

    func settingsChanged() {
        let previous = state.settings
        state.settings = context.settings(ClipboardSettings.self).clamped
        store.capacity = state.settings.items
        guard previous.shortcut != state.settings.shortcut else { return }
        mirrorShortcut()
        if hotkeys != nil { registerShortcut() }
    }

    /// `[clipboard]` decides; the preferences keep a copy of its shortcut, since Frog's shortcut conflict checks,
    /// the shortcut reference, the window switcher and a Reload or Import read it there. A shortcut written into
    /// config.toml by hand that another one already uses is left unregistered, and the page says why.
    private func mirrorShortcut() {
        shortcutClash = nil
        do { try mirror(state.settings.shortcut.hotkey) } catch { shortcutClash = error.localizedDescription }
        state.shortcutIssue = shortcutClash
    }

    private func mirror(_ hotkey: Hotkey) throws {
        var workflow = model.configuration.preferences.workflowSettings
        guard workflow.effectiveClipboardHistoryHotkey != hotkey else { return }
        workflow.clipboardHistoryHotkey = hotkey
        try model.saveWorkflowPreferences(workflow)
    }

    /// Reload and Import write the old `config`, whose `shortcut.clipboard` key `[clipboard]` then follows,
    /// whether the plugin runs or not.
    static func adoptLegacySettings(_ model: AppModel) {
        let file = model.settingsFile
        let hotkey = model.configuration.preferences.workflowSettings.effectiveClipboardHistoryHotkey
        do {
            var settings = (try? file.section(info.id, as: ClipboardSettings.self).value) ?? ClipboardSettings()
            guard settings.shortcut.hotkey != hotkey else { return }
            settings.shortcut = try Shortcut(hotkey)
            try file.update(info.id, settings)
        } catch { model.report(error) }
        model.pluginHost.running[info.id]?.settingsChanged()
    }

    private func seedSettingsIfNeeded() {
        let file = model.settingsFile
        guard file.document.value(at: [Self.info.id]) == nil else { return }
        let seed = ClipboardSettings.seed(from: model.configuration.preferences)
        do { try file.edit { try $0.update(Self.info.id, seed, all: true) } } catch { context.report(error) }
    }

    private func registerShortcut() {
        guard model.runsLiveServices, !model.isRecordingShortcut else { return }
        let hotkeys = self.hotkeys ?? HotkeyManager()
        self.hotkeys = hotkeys
        guard shortcutClash == nil else { hotkeys.unregister(); state.shortcutIssue = shortcutClash; return }
        let rule = Rule(id: Self.shortcutID, name: "Clipboard history", hotkey: state.settings.shortcut.hotkey)
        // Opens on the press: the panel is there before the keys are up.
        let errors = hotkeys.register(rules: [rule], purposes: [Self.shortcutID: .clipboardHistory],
                                      onPress: { [weak self] _ in self?.show() }, onTrigger: { _ in })
        state.shortcutIssue = errors[Self.shortcutID]
    }

    func show() {
        guard !model.isRecordingShortcut else { return }
        controller?.show()
    }

    // MARK: Settings from the page

    func setShortcut(_ hotkey: Hotkey) {
        do {
            if let issue = HotkeyManager.validationError(hotkey, purpose: .clipboardHistory) { throw FrogError.message(issue) }
            var settings = state.settings
            settings.shortcut = try Shortcut(hotkey)
            // The preferences' copy first: a shortcut another one uses is refused before anything is written.
            try mirror(hotkey)
            shortcutClash = nil
            try save(settings)
            registerShortcut()
        } catch { context.report(error) }
    }

    func setItems(_ items: Int) {
        var settings = state.settings
        settings.items = items
        settings = settings.clamped
        do { try save(settings) } catch { context.report(error) }
    }

    private func save(_ settings: ClipboardSettings) throws {
        try context.save(settings)
        state.settings = settings
        store.capacity = settings.items
    }

    // MARK: Surfaces

    func page() -> AnyView? { legacyPage(ClipboardPage(plugin: self, store: store, state: state)) }

    var menu: [MenuContribution] {
        [MenuContribution(id: "clipboard.open", order: 21) { [weak self, state] in
            AnyView(MenuActionRow(title: "Clipboard history", symbol: "clipboard",
                                  key: HotkeyManager.display(state.settings.shortcut.hotkey), closes: true) {
                self?.show()
            })
        }]
    }

    var actions: [PluginAction] {
        let id = ActionParameter(name: "id", required: true, help: "The item's ID from clipboard.list, or its start: at least 4 characters")
        let plain = ActionParameter(name: "plain", kind: .boolean, help: "Without formatting")
        let limit = ActionParameter(name: "limit", kind: .integer, help: "How many, newest first; 20 by default")
        return [
            PluginAction(id: "clipboard.show", title: "Clipboard history", symbol: "doc.on.clipboard",
                         keywords: "paste copied history", surfaces: [.commandBar, .shortcut, .agent]) { [weak self] _ in
                self?.show(); return .done()
            },
            PluginAction(id: "clipboard.list", title: "List copied text", symbol: "list.bullet", parameters: [limit],
                         surfaces: .agent) { [weak self] input in
                guard let self else { throw CancellationError() }
                return try Self.listing(Array(self.store.entries.prefix(try Self.limit(input))), empty: "Nothing copied yet.")
            },
            PluginAction(id: "clipboard.search", title: "Search copied text", symbol: "magnifyingglass",
                         parameters: [ActionParameter(name: "query", required: true, help: "Words to find, in any order"), limit],
                         surfaces: .agent) { [weak self] input in
                guard let self else { throw CancellationError() }
                let found = ClipboardSearch.filter(self.store.entries, query: try input.required("query"))
                return try Self.listing(Array(found.prefix(try Self.limit(input))), empty: "No copied text matches.")
            },
            PluginAction(id: "clipboard.copy", title: "Copy an item again", symbol: "doc.on.doc", parameters: [id, plain],
                         surfaces: .agent) { [weak self] input in
                guard let self else { throw CancellationError() }
                let entry = try self.entry(input)
                guard self.store.copy(entry, plainText: try input.boolean("plain") ?? false) else { throw ActionError.failed("Could not copy the item.") }
                return .done("Copied.")
            },
            PluginAction(id: "clipboard.paste", title: "Paste an item", symbol: "doc.on.clipboard", parameters: [id, plain],
                         surfaces: .agent) { [weak self] input in
                guard let self, let controller = self.controller else { throw CancellationError() }
                try await controller.paste(try self.entry(input), plainText: try input.boolean("plain") ?? false)
                return .done("Pasted.")
            },
            PluginAction(id: "clipboard.clear", title: "Clear clipboard history", symbol: "trash",
                         keywords: "forget delete copied", surfaces: [.commandBar, .agent]) { [weak self] _ in
                self?.store.clear(); return .done("Cleared.")
            },
        ]
    }

    private func entry(_ input: ActionInput) throws -> ClipboardHistoryEntry {
        let id = try input.required("id")
        let matches = store.entries(id: id)
        guard matches.count < 2 else { throw ActionError.failed("“\(id)” matches several items; give more characters.") }
        guard let entry = matches.first else {
            throw ActionError.failed(id.count < ClipboardHistoryStore.shortestID
                ? "Give at least \(ClipboardHistoryStore.shortestID) characters of the ID."
                : "No copied item “\(id)”. Run `frog run clipboard.list` for the IDs.")
        }
        return entry
    }

    private static func limit(_ input: ActionInput) throws -> Int {
        let limit = try input.integer("limit") ?? 20
        guard (1...ClipboardHistoryStore.maxCapacity).contains(limit) else {
            throw ActionError.invalid("limit", "a number from 1 to \(ClipboardHistoryStore.maxCapacity)")
        }
        return limit
    }

    private struct Item: Encodable {
        let id: String
        let copied: Date
        let text: String
        let formatted: Bool
    }

    /// One line per item for people, `id  time  text`; every field, the whole text included, as JSON.
    private static func listing(_ entries: [ClipboardHistoryEntry], empty: String) throws -> ActionResult {
        let items = entries.map { Item(id: $0.id.uuidString.lowercased(), copied: $0.timestamp, text: $0.text, formatted: !$0.formatting.isEmpty) }
        let lines = entries.map { "\($0.shortID)  \(AgentCommands.shortTime($0.timestamp))  \(String($0.preview.prefix(80)))" }
        return ActionResult(items, text: lines.isEmpty ? empty : lines.joined(separator: "\n"))
    }
}

/// What the Clipboard page shows of the plugin: its settings and why its shortcut did not register.
@MainActor @Observable final class ClipboardPageState {
    var settings = ClipboardSettings()
    var shortcutIssue: String?
}
