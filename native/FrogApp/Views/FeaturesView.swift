import SwiftUI
import FrogCore

/// Turns plugins on and off, by sidebar category. Each plugin's settings are on its own page.
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
            FrogPageHeader(title: "Plugins")
            SearchBox(placeholder: "Find a plugin", text: $search)
            let groups = groups
            if groups.isEmpty {
                FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try another word.")
            } else {
                ForEach(groups, id: \.category) { group in
                    // Captioned like a `FrogSection`, so this page reads like the others.
                    VStack(alignment: .leading, spacing: FrogStyle.space8) {
                        Text(L10n.text(group.category.title)).font(FrogType.section).foregroundStyle(FrogStyle.ink)
                            .accessibilityAddTraits(.isHeader).frame(minHeight: 20).padding(.horizontal, FrogStyle.space2)
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
                Text(L10n.text(plugin.summary)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if enabled {
                Button("Open") { host.open(plugin.id) }
                    .buttonStyle(.frog(.ghost, compact: true))
                    .accessibilityLabel("Open \(plugin.name)")
            }
            Toggle(plugin.name, isOn: Binding(get: { enabled }, set: { on in
                pending.insert(plugin.id)
                Task {
                    defer { pending.remove(plugin.id) }
                    do { try await host.setEnabled(plugin.id, on) } catch { model.report(error) }
                }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(pending.contains(plugin.id))
        }.padding(.horizontal, FrogStyle.rowPadding).padding(.vertical, FrogStyle.space6).frogHoverRow()
    }
}
