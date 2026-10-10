import SwiftUI
import FrogCore
import FrogUsage

struct FeaturesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var pending = Set<FeatureID>()
    var body: some View {
        ScrollViewReader { proxy in
            PageScroll {
                PageHeader(title: "Features", subtitle: "Choose the tools that belong in your Frog.")
                SearchBox(placeholder: "Find a feature", text: $search)
                ForEach(FeatureID.allCases.filter { search.isEmpty || ($0.title + " " + $0.detail).localizedStandardContains(search) }) { feature in
                    featureCard(feature).id(feature)
                }
            }
            .task(id: model.toolkit.featureSettingsSelection) {
                if let feature = model.toolkit.featureSettingsSelection {
                    search = ""
                    await Task.yield()
                    proxy.scrollTo(feature, anchor: .top)
                }
            }
        }
    }
    private func featureCard(_ feature: FeatureID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: feature.symbol).font(.system(size: 17)).frame(width: 26, height: 28).foregroundStyle(FrogStyle.muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text(feature.title).font(.system(size: 13, weight: .medium))
                    Text(feature.detail).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                    if feature.hasPage, model.configuration.preferences.featureEnabled(feature) {
                        Button("Open") { model.openFeature(feature) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(FrogStyle.accent)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle(feature.title, isOn: Binding(get: { model.configuration.preferences.featureEnabled(feature) }, set: { enabled in
                    pending.insert(feature)
                    Task {
                        defer { pending.remove(feature) }
                        do { try await model.setFeature(feature, enabled: enabled) } catch { model.report(error) }
                    }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(pending.contains(feature))
            }
            if model.configuration.preferences.featureEnabled(feature) {
                if feature == .windowSwitcher {
                    Divider().opacity(0.5)
                    WindowSwitcherFeatureView()
                } else if feature == .clipboard {
                    Divider().opacity(0.5)
                    ClipboardFeatureView()
                }
            }
        }.padding(14).frogTableSurface()
    }
}

struct CommandBarSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        PageScroll {
            PageHeader(title: "Command bar", subtitle: "Applications, windows, files and Frog tools, one shortcut away.")
            SettingsSection(title: "Shortcut") {
                CompactRow(title: "Open command bar") {
                    HotkeyRecorder(hotkey: Binding(get: { model.configuration.preferences.toolkitSettings.effectiveCommandBarHotkey }, set: { key in
                        var prefs = model.configuration.preferences
                        if prefs.toolkit == nil { prefs.toolkit = ToolkitPreferences() }
                        prefs.toolkit?.commandBarHotkey = key
                        do { try model.savePreferences(prefs) } catch { model.report(error) }
                    }), showsClearButton: false)
                    Button("Open") { model.showCommandBar() }
                }
                if let issue = model.hotkeyErrors[AppModel.commandBarID] { Text(issue).font(.caption).foregroundStyle(.orange) }
            }
            Text("Type an application, window or filename. You can also calculate 25% * 200 or convert 5 mi to km. Arrow keys select a result; Return opens it and Escape closes the panel.")
                .font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
            CommandBarSetupView()
        }
    }
}
