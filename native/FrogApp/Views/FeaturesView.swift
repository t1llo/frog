import SwiftUI
import FrogCore

/// Turns Frog's built-in features on and off, by sidebar category. Each plugin's settings are on its own page.
struct PluginsCatalogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pending = Set<String>()

    private var groups: [(category: PluginCategory, plugins: [PluginInfo])] {
        let infos = model.pluginHost.descriptors.map(\.info)
        return PluginCategory.allCases.compactMap { category in
            let plugins = infos.filter { $0.category == category }
            return plugins.isEmpty ? nil : (category, plugins)
        }
    }

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Features", subtitle: "Turn Frog's built-in features on or off. Each has its own page.")
            // No search of its own: the sidebar's search above already finds features, and two fields stacked
            // one under the other read as two different searches.
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

    /// A feature: its tile, name and summary, its switch, and a chevron that opens its page while it is on (the whole
    /// row does). A feature that will not work yet says why in place of its summary, in the warning colour behind one
    /// mark; its page says how to fix it.
    private func row(_ plugin: PluginInfo) -> some View {
        let host = model.pluginHost
        let enabled = host.enabled(plugin.id)
        let problem = enabled ? problem(plugin.id) : nil
        return HStack(spacing: 12) {
            PluginIconTile(symbol: plugin.symbol, tint: plugin.tint.color, size: .list)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(plugin.name)).font(FrogType.row)
                if let problem {
                    Label(L10n.text(problem), systemImage: "exclamationmark.triangle.fill")
                        .font(FrogType.small).foregroundStyle(FrogStyle.warning).lineLimit(1).help(problem)
                } else {
                    Text(L10n.text(plugin.summary)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(plugin.name, isOn: Binding(get: { enabled }, set: { on in
                pending.insert(plugin.id)
                Task {
                    defer { pending.remove(plugin.id) }
                    do { try await host.setEnabled(plugin.id, on) } catch { model.report(error) }
                }
            })).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small).disabled(pending.contains(plugin.id))
            // A button, so the keyboard reaches the page too (Tab with keyboard navigation on), not only the pointer.
            Button { host.open(plugin.id) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(FrogStyle.muted)
                    .frame(width: FrogStyle.compactHeight, height: FrogStyle.compactHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("\(L10n.text("Open")) \(L10n.text(plugin.name))").accessibilityLabel("\(L10n.text("Open")) \(L10n.text(plugin.name))")
            .opacity(enabled ? 1 : 0).disabled(!enabled).accessibilityHidden(!enabled)
        }
        .padding(.horizontal, FrogStyle.rowPadding).padding(.vertical, FrogStyle.space6)
        .contentShape(Rectangle())
        // A click on the switch while it is still turning the feature on or off lands here, the switch being
        // disabled meanwhile: it must not open the page.
        .onTapGesture { if enabled, !pending.contains(plugin.id) { host.open(plugin.id) } }
        .frogHoverRow()
        .accessibilityElement(children: .contain)
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
            ? "Won't work yet: choose a model on its page." : "Won't work yet: \(blocked.count == 1 ? "a rule has" : "\(blocked.count) rules have") no model."
    }
}
