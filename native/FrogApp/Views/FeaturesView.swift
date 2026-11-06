import SwiftUI
import FrogCore

/// Turns Frog's built-in features on and off, by sidebar category. Each plugin's settings are on its own page.
struct PluginsCatalogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var pending = Set<String>()

    private var groups: [(category: PluginCategory, plugins: [PluginInfo])] {
        let infos = model.pluginHost.descriptors.map(\.info)
            .filter { search.isEmpty || ($0.name + " " + $0.summary).localizedStandardContains(search) }
        return PluginCategory.allCases.compactMap { category in
            let plugins = infos.filter { $0.category == category }
            return plugins.isEmpty ? nil : (category, plugins)
        }
    }

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Features", subtitle: "Turn Frog's built-in features on or off. Each has its own page.")
            SearchBox(placeholder: "Find a feature", text: $search)
            let groups = groups
            if groups.isEmpty {
                FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try another word.")
            } else {
                ForEach(groups, id: \.category) { group in
                    // Captioned like a `FrogSection`, so this page reads like the others.
                    VStack(alignment: .leading, spacing: FrogStyle.space8) {
                        FrogSectionHeader(group.category.title)
                        VStack(spacing: FrogStyle.space2) {
                            ForEach(group.plugins) { row($0) }
                        }.padding(FrogStyle.listInset).frogTableSurface()
                    }
                }
            }
        }
    }

    private func row(_ plugin: PluginInfo) -> some View {
        let host = model.pluginHost
        let enabled = host.enabled(plugin.id)
        return HStack(spacing: 12) {
            PluginIconTile(symbol: plugin.symbol, tint: plugin.tint.color, size: .list)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(plugin.name)).font(FrogType.bodyMedium)
                if enabled, let problem = problem(plugin.id) {
                    Label { Text(L10n.text(problem)) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(FrogType.small).foregroundStyle(FrogStyle.warning).lineLimit(1)
                } else {
                    Text(L10n.text(plugin.summary)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if enabled {
                Button("Open") { host.open(plugin.id) }
                    .buttonStyle(.frog(compact: true))
                    .accessibilityLabel("Open \(plugin.name)")
            }
            Toggle(plugin.name, isOn: Binding(get: { enabled }, set: { on in
                pending.insert(plugin.id)
                Task {
                    defer { pending.remove(plugin.id) }
                    do { try await host.setEnabled(plugin.id, on) } catch { model.report(error) }
                }
            })).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small).disabled(pending.contains(plugin.id))
        }.padding(.horizontal, FrogStyle.rowPadding).padding(.vertical, FrogStyle.space6).frogHoverRow()
    }

    /// Why a feature that is on will not work yet: its rules have no model.
    private func problem(_ id: String) -> String? {
        let rules = model.configuration.rules.filter(\.enabled)
        let blocked: [Rule]
        switch id {
        case BuiltinPlugins.pluginID(for: .writing): blocked = rules.filter { $0.isWritingRule && !model.ruleHasModel($0) }
        case BuiltinPlugins.pluginID(for: .explain): blocked = rules.filter { $0.isExplainRule && !model.ruleHasModel($0) }
        case BuiltinPlugins.pluginID(for: .dictation): blocked = rules.filter { $0.category == .audio && !model.ruleHasModel($0) }
        default: return nil
        }
        if blocked.isEmpty { return nil }
        return blocked.count == 1 && id != BuiltinPlugins.pluginID(for: .writing)
            ? "Won't work yet: choose a model" : "Won't work yet: \(blocked.count == 1 ? "a rule has" : "\(blocked.count) rules have") no model"
    }
}
