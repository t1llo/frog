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
        PageScroll {
            PageHeader(title: "Plugins")
            SearchBox(placeholder: "Find a plugin", text: $search)
            let groups = groups
            if groups.isEmpty {
                FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try another word.")
            } else {
                ForEach(groups, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        SectionCaption(text: group.category.title).padding(.leading, 4)
                        VStack(spacing: 2) {
                            ForEach(group.plugins) { row($0) }
                        }.padding(6).frogTableSurface()
                    }
                }
            }
        }
    }

    private func row(_ plugin: PluginInfo) -> some View {
        let host = model.pluginHost
        let enabled = host.enabled(plugin.id)
        return HStack(spacing: 12) {
            PluginTile(symbol: plugin.symbol, tint: plugin.tint.color, size: 28)
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
        }.padding(.horizontal, 8).padding(.vertical, 6).frogHoverRow()
    }
}

/// A plugin's icon: its symbol in white on a rounded tile of its colour, as in System Settings.
struct PluginTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
