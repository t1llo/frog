import SwiftUI
import AppKit
import FrogCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    private var section: ToolkitRoute { model.toolkit.route }
    @State private var permissionsRequest = ScrollRequest()

    private struct NavigationItem: Identifiable {
        let id: ToolkitRoute
        let title: String
        let symbol: String
        var key: KeyEquivalent?
        /// A small symbol at the row's end, such as the pin of a pinned feature.
        var marker: String?
    }
    private func featureItem(_ feature: FeatureID, marker: String?) -> NavigationItem {
        NavigationItem(id: .feature(feature), title: feature.title, symbol: feature.symbol,
            key: feature == .writing ? "1" : feature == .applicationShortcuts ? "4" : nil, marker: marker)
    }
    private var workspaceNavigation: [NavigationItem] {
        [NavigationItem(id: .history, title: "History", symbol: "clock.arrow.circlepath", key: "2"),
            NavigationItem(id: .models, title: "Models", symbol: "cpu", key: "3"),
            NavigationItem(id: .features, title: "Features", symbol: "square.grid.2x2"),
            NavigationItem(id: .settings, title: "Settings", symbol: "slider.horizontal.3", key: "5")
        ]
    }
    @ViewBuilder private var selectedPage: some View {
        switch section {
        case .history: HistoryView()
        case .models: ProvidersView()
        case .features: FeaturesView()
        case .settings: PreferencesView(permissionsRequest: $permissionsRequest)
        case .statistics: StatisticsView(statistics: model.statistics, onBack: { model.toolkit.select(.settings) })
        case .feature(let feature):
            switch feature {
            case .writing: RulesView(fixedCategory: .text)
            case .dictation: RulesView(fixedCategory: .audio, output: .replace) { RecordingSettingsView() }
            case .applicationShortcuts: RulesView(applications: true)
            case .windowSwitcher: WindowSwitcherView()
            case .clipboard: ClipboardView()
            case .systemMonitor: SystemMonitorPage(monitor: model.systemMonitor)
            case .commandBar: CommandBarSettingsView()
            case .usage:
                if let usage = model.toolkit.usage() { UsageDashboardView(usage: usage) }
            case .stayAwake: StayAwakeView(power: model.power)
            case .scratchpad: UtilityDocumentsView(documents: model.documents, kind: .note)
            case .scripts: UtilityDocumentsView(documents: model.documents, kind: .script)
            case .menuBar:
                MenuBarSettingsView(organizer: model.toolkit.menuBarOrganizer, settings: Binding(
                    get: { model.configuration.preferences.toolkitSettings.menuBar ?? MenuBarPreferences() },
                    set: { value in
                        do { try model.updateToolkit { $0.menuBar = value.normalized } } catch { model.report(error) }
                    }))
            case .explain: ExplainView()
            case .windows: WindowsView()
            case .cleaner: CleanerView(cleaner: model.cleaner)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 176)
                .overlay(alignment: .trailing) { Rectangle().fill(FrogStyle.border.opacity(0.6)).frame(width: 1) }
            VStack(spacing: 0) {
                selectedPage.id(section).frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = model.errorMessage {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(FrogStyle.critical)
                        Text(error).font(.system(size: 12)).textSelection(.enabled)
                            .lineLimit(3).help("Full details are in Settings → Logs.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        IconAction(title: "Copy error", symbol: "doc.on.doc") { ViewActions.copy(error) }
                        Button { model.dismissError() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                    }.padding(16).background(FrogStyle.surface)
                        .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border).frame(height: 1) }
                }
            }.clipped().padding(.top, 32).background(FrogStyle.canvas)
        }
        .font(.system(size: 13)).foregroundStyle(FrogStyle.ink)
        .environment(\.locale, L10n.locale)
        .background(FrogWindowMaterial())
        .ignoresSafeArea(.container, edges: .top)
        .tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
        .frame(minWidth: 740, minHeight: 520)
        .onAppear { model.refreshSystemStatus() }
        .sheet(isPresented: Binding(get: { model.setupPresented }, set: { if !$0 { model.finishSetup() } })) {
            SetupView().environmentObject(model).interactiveDismissDisabled()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(nsImage: FrogMenuIcon.image).renderingMode(.template).frame(width: 20)
                    Text("Frog").font(.system(size: 14, weight: .semibold)).tracking(-0.2)
                }.padding(.horizontal, 16).padding(.top, 19).padding(.bottom, 23)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { WindowDragRegion().accessibilityHidden(true) }

                ScrollViewReader { proxy in
                    ScrollView {
                        SidebarFeatureList(features: model.toolkit.sidebar) { feature, marker in
                            navigationButton(featureItem(feature, marker: marker)).id(ToolkitRoute.feature(feature))
                        }.padding(.horizontal, 8)
                    }
                    .onChange(of: section) { _, route in
                        if case .feature = route { proxy.scrollTo(route, anchor: .center) }
                    }
                }
            }.padding(.top, 32).background(FrogStyle.sidebar)
            VStack(spacing: 2) { ForEach(workspaceNavigation) { navigationButton($0) } }
                .padding(8).padding(.vertical, 4)
                .background(FrogStyle.surface)
                .background(FrogStyle.canvas)
                .overlay(alignment: .top) { Rectangle().fill(FrogStyle.border.opacity(0.6)).frame(height: 1) }
            if !model.accessibilityGranted || !DictationController.microphoneGranted {
                Button {
                    model.toolkit.select(.settings); permissionsRequest.ask()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(FrogStyle.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Finish setup").font(.system(size: 11, weight: .medium))
                            Text(L10n.text(!model.accessibilityGranted ? "Allow Accessibility" : "Allow Microphone"))
                                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                        }
                        Spacer(minLength: 0)
                    }.padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 6).padding(.bottom, 10)
                    .background(FrogStyle.sidebar)
            }
        }
    }
    private func navigationButton(_ item: NavigationItem) -> some View {
        Button { model.toolkit.select(item.id) } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 18)
                Text(L10n.text(item.title)).font(.system(size: 12, weight: section == item.id ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let marker = item.marker {
                    Image(systemName: marker).font(.system(size: 9)).foregroundStyle(FrogStyle.muted).accessibilityHidden(true)
                }
            }
            .foregroundStyle(section == item.id ? FrogStyle.ink : FrogStyle.muted)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(section == item.id ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
            .contentShape(RoundedRectangle(cornerRadius: FrogStyle.corner))
        }.buttonStyle(.plain).optionalNavigationShortcut(item.key)
            .accessibilityAddTraits(section == item.id ? .isSelected : []).help(item.title)
    }
}

/// A request to open a page at one of its sections. The page takes the request when it
/// scrolls there, so it is answered once and a later visit opens the page at its top.
struct ScrollRequest {
    private(set) var id: UUID?
    mutating func ask() { id = UUID() }
    /// Whether a scroll is still owed. Taking it uses the request up.
    mutating func take() -> Bool {
        defer { id = nil }
        return id != nil
    }
}

enum ViewActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private extension View {
    @ViewBuilder func optionalNavigationShortcut(_ key: KeyEquivalent?) -> some View {
        if let key { keyboardShortcut(key, modifiers: .command) } else { self }
    }
}

struct InlineIssue: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 12)).foregroundStyle(FrogStyle.ink)
            .fixedSize(horizontal: false, vertical: true).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FrogStyle.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: FrogStyle.cardRadius))
    }
}
