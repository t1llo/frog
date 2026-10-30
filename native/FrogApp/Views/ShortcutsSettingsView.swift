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
            FrogSection("Apps", accessory: { addApp }) {
                if apps.isEmpty { FrogRowNote(text: catalog.scanned ? "Add an app, then record its keys." : "Looking for apps…") }
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
                if actions.isEmpty { FrogRowNote(text: "Add an action, such as Lock screen or Open the command bar.") }
                ForEach(actions, id: \.self) { index in
                    row(index) {
                        Image(systemName: symbol(of: bindings[index])).frame(width: 20, height: 20).foregroundStyle(FrogStyle.muted)
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

    private var addApp: some View {
        let byPath = Dictionary(catalog.installed.compactMap { rule in rule.action?.applicationPath.map { ($0, rule) } }, uniquingKeysWith: { first, _ in first })
        return FrogDropdown(selected: String?.none, sections: [FrogDropdownSection(values: catalog.installed.compactMap(\.action?.applicationPath))],
                            width: 120, compact: true, searchPrompt: "Search apps", placeholder: "Add app",
                            emptyMessage: "Looking for apps…",
                            item: { path in FrogDropdownItem(path.flatMap { byPath[$0]?.name } ?? "") }) { path in
            guard let path, let rule = byPath[path] else { return }
            // The path tells apart copies that share a bundle ID, such as Xcode and Xcode-beta.
            let with = rule.action?.applicationBundleID.map { ["app": $0, "path": path] } ?? ["app": path]
            save(plugin.bindings + [ShortcutBinding(key: nil, action: ShortcutBinding.openApp, with: with)])
        }
    }

    /// Actions that run with nothing typed, by plugin, then the Mac commands.
    private var addAction: some View {
        let host = model.pluginHost
        let runnable = host.actions.filter { $0.surfaces.contains(.shortcut) && !$0.parameters.contains(where: \.required) }
        let byPlugin = Dictionary(grouping: runnable, by: \.pluginID)
        let sections = host.descriptors.compactMap { descriptor -> FrogDropdownSection<String?>? in
            guard let actions = byPlugin[descriptor.id], !actions.isEmpty else { return nil }
            return FrogDropdownSection(descriptor.info.name, values: actions.map { Optional($0.id) })
        } + [FrogDropdownSection("Mac", values: SystemAction.allCases.map { Optional("system:\($0.rawValue)") })]
        return FrogDropdown(selected: String?.none, sections: sections, width: 120, compact: true, searchPrompt: "Search actions",
                            placeholder: "Add action",
                            item: { value in
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
