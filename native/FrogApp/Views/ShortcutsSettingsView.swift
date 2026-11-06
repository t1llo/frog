import AppKit
import SwiftUI
import FrogCore

/// Keys that open apps and keys that run actions. Each row is one binding of `[shortcuts]` in config.toml.
struct ShortcutsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let plugin: ShortcutsPlugin
    @ObservedObject private var catalog = ApplicationCatalogStore.shared

    var body: some View {
        let bindings = plugin.bindings
        let apps = bindings.indices.filter { bindings[$0].app != nil }
        let actions = bindings.indices.filter { bindings[$0].app == nil }
        FrogPage {
            FrogPageHeader(title: "Shortcuts", subtitle: "Keys that open apps and run actions from anywhere")
            if let unreadable = plugin.unreadable { FrogRowNote(text: unreadable, tone: FrogStyle.warning) }
            if apps.isEmpty, actions.isEmpty, catalog.scanned {
                // Nothing yet: one quiet card with both ways to start, not two empty sections.
                FrogEmptyState(symbol: "command", title: "No shortcuts yet",
                               message: "Open apps and run actions with keys of your own, from anywhere.") {
                    HStack(spacing: FrogStyle.space8) {
                        ShortcutAddButton(title: "Add app", list: appList, primary: false)
                        ShortcutAddButton(title: "Add action", list: actionList, primary: false)
                    }
                }.frogTableSurface()
            } else {
                FrogSection("Apps", accessory: { addApp }) {
                    if apps.isEmpty, catalog.scanned {
                        FrogRow("No app shortcuts yet", caption: "Open any app with keys of your own.")
                    } else if apps.isEmpty {
                        FrogLoadingNote(text: "Looking for apps…")
                            .frame(maxWidth: .infinity, minHeight: FrogStyle.rowHeight, alignment: .leading)
                    }
                    ForEach(apps, id: \.self) { index in
                        row(index) {
                            if let app = bindings[index].app, let url = ShortcutsPlugin.applicationURL(app, path: bindings[index].with["path"]) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "questionmark.app").frame(width: 20, height: 20).foregroundStyle(FrogStyle.muted)
                            }
                        }
                    }
                }
                FrogSection("Actions", accessory: { addAction }) {
                    if actions.isEmpty {
                        FrogRow("No action shortcuts yet", caption: "Lock the screen, open the command bar or run any Frog action.")
                    }
                    ForEach(actions, id: \.self) { index in
                        row(index) {
                            Image(systemName: symbol(of: bindings[index])).frame(width: 20, height: 20).foregroundStyle(FrogStyle.muted)
                        }
                    }
                }
            }
        }
        .task { await catalog.loadIfNeeded() }
    }

    private func row<Icon: View>(_ index: Int, @ViewBuilder icon: () -> Icon) -> some View {
        let binding = plugin.bindings[index]
        let issue = plugin.issue(at: index)
        return FrogRow(plugin.title(of: binding), caption: issue ?? caption(of: binding), icon: icon) {
            HStack(spacing: 6) {
                HotkeyRecorder(hotkey: Binding(get: { binding.key?.hotkey }, set: { hotkey in
                    do { try plugin.setKey(hotkey.flatMap { try? Shortcut($0) }, at: index) } catch { model.report(error) }
                }), showsClearButton: false)
                Button { save(plugin.bindings.enumerated().filter { $0.offset != index }.map(\.element)) } label: {
                    Image(systemName: "minus")
                }.buttonStyle(.frog(.ghost)).help("Remove").accessibilityLabel("Remove \(plugin.title(of: binding))")
            }
        }
    }

    private func caption(of binding: ShortcutBinding) -> String? {
        guard binding.app == nil, binding.action != ShortcutBinding.system else { return nil }
        let plugin = String(binding.action.prefix { $0 != "." })
        return model.pluginHost.descriptor(plugin)?.info.name
    }

    private func symbol(of binding: ShortcutBinding) -> String {
        if binding.action == ShortcutBinding.system, let command = binding.with["command"].flatMap(SystemAction.init(rawValue:)) { return command.symbol }
        return model.pluginHost.action(binding.action)?.symbol ?? "bolt"
    }

    private func save(_ next: [ShortcutBinding]) {
        do { try plugin.save(next) } catch { model.report(error) }
    }

    // MARK: Adding

    private var addApp: some View { ShortcutAddButton(title: "Add app", list: appList, primary: false) }

    private var addAction: some View { ShortcutAddButton(title: "Add action", list: actionList, primary: false) }

    /// Installed apps, by name.
    private var appList: ShortcutChoices {
        let byPath = Dictionary(catalog.installed.compactMap { rule in rule.action?.applicationPath.map { ($0, rule) } }, uniquingKeysWith: { first, _ in first })
        return ShortcutChoices(sections: [FrogDropdownSection(values: catalog.installed.compactMap(\.action?.applicationPath))],
                               searchPrompt: "Search apps", emptyMessage: "Looking for apps…",
                               item: { path in FrogDropdownItem(path.flatMap { byPath[$0]?.name } ?? "") }) { path in
            guard let path, let rule = byPath[path] else { return }
            // The path tells apart copies that share a bundle ID, such as Xcode and Xcode-beta.
            let with = rule.action?.applicationBundleID.map { ["app": $0, "path": path] } ?? ["app": path]
            save(plugin.bindings + [ShortcutBinding(key: nil, action: ShortcutBinding.openApp, with: with)])
        }
    }

    /// Actions that run with nothing typed, by plugin, then the Mac commands.
    private var actionList: ShortcutChoices {
        let host = model.pluginHost
        let runnable = host.actions.filter { $0.surfaces.contains(.shortcut) && !$0.parameters.contains(where: \.required) }
        let byPlugin = Dictionary(grouping: runnable, by: \.pluginID)
        let sections = host.descriptors.compactMap { descriptor -> FrogDropdownSection<String?>? in
            guard let actions = byPlugin[descriptor.id], !actions.isEmpty else { return nil }
            return FrogDropdownSection(descriptor.info.name, values: actions.map { Optional($0.id) })
        } + [FrogDropdownSection("Mac", values: SystemAction.allCases.map { Optional("system:\($0.rawValue)") })]
        return ShortcutChoices(sections: sections, searchPrompt: "Search actions", item: { value in
            guard let value else { return FrogDropdownItem("") }
            if value.hasPrefix("system:"), let command = SystemAction(rawValue: String(value.dropFirst(7))) {
                return FrogDropdownItem(command.title, detail: command.scope, symbol: command.symbol)
            }
            let action = host.action(value)
            return FrogDropdownItem(action?.title ?? value, symbol: action?.symbol)
        }) { value in
            guard let value else { return }
            let binding = value.hasPrefix("system:")
                ? ShortcutBinding(key: nil, action: ShortcutBinding.system, with: ["command": String(value.dropFirst(7))])
                : ShortcutBinding(key: nil, action: value)
            save(plugin.bindings + [binding])
        }
    }
}

/// What an add list offers: drawn by the header's dropdown, or by the empty state's button.
private struct ShortcutChoices {
    let sections: [FrogDropdownSection<String?>]
    var searchPrompt: String? = nil
    var emptyMessage = "Nothing to choose from."
    let item: (String?) -> FrogDropdownItem
    let choose: (String?) -> Void
}

/// The add button of a section or of the empty page (both secondary; primary stays available): `FrogAddButton`'s pill with a chevron,
/// opening a searchable list, since apps and actions are too many for a menu.
private struct ShortcutAddButton: View {
    let title: String
    let list: ShortcutChoices
    var primary = true
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { FrogAddLabel(title: title, menu: true) }
            .buttonStyle(.frog(primary ? .primary : .secondary)).accessibilityLabel(L10n.text(title))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                FrogDropdownList(sections: list.sections, selected: nil, item: list.item, searchPrompt: list.searchPrompt,
                                 emptyMessage: list.emptyMessage, width: 320) { value in
                    showing = false
                    list.choose(value)
                } dismiss: { showing = false }
            }
    }
}
