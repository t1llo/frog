import SwiftUI
import AppKit
import FrogCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var section: ToolkitRoute { model.toolkit.route }
    @State private var permissionsRequest = ScrollRequest()

    fileprivate struct NavigationItem: Identifiable {
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
        case .plugin(let id): PluginPageView(id: id)
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
            case .phone: PhoneView()
            case .plugins: PluginsView(plugins: model.plugins)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 176)
            VStack(spacing: 0) {
                selectedPage.id(section).frame(maxWidth: .infinity, maxHeight: .infinity)
                // Errors are occasional: the banner rises into place (fades with Reduce Motion) and leaves a little faster.
                // The page beside it does not animate.
                VStack(spacing: 0) {
                    if let error = model.errorMessage {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(FrogStyle.critical)
                            Text(error).font(FrogType.body).textSelection(.enabled)
                                .lineLimit(3).help("Full details are in Settings → Logs.")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            CopyAction(title: "Copy error") { ViewActions.copy(error) }
                            IconAction(title: "Dismiss error", symbol: "xmark", action: model.dismissError)
                        }.padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
                            .background(FrogStyle.critical.opacity(0.08), in: RoundedRectangle(cornerRadius: FrogStyle.cardRadius))
                            .padding(.horizontal, 20).padding(.bottom, 16)
                            .transition(.asymmetric(insertion: reduceMotion ? .opacity : .offset(y: 8).combined(with: .opacity), removal: .opacity))
                    }
                }.animation(model.errorMessage == nil ? FrogMotion.exit : FrogMotion.reveal, value: model.errorMessage)
            }.clipped().padding(.top, 32).background(FrogStyle.canvas)
                .sheet(item: Binding(get: { model.pluginReview }, set: { if $0 == nil { model.pluginRuntime?.dismissReview() } })) { review in
                    PluginReviewSheet(review: review, plugins: model.plugins) { model.report($0) }
                }
        }
        .font(FrogType.lead).foregroundStyle(FrogStyle.ink)
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

    private func reveal(_ route: ToolkitRoute, in proxy: ScrollViewProxy) {
        switch route {
        case .feature, .plugin: proxy.scrollTo(route)
        default: break
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(nsImage: FrogMenuIcon.image).renderingMode(.template).frame(width: 20)
                    Text("Frog").font(FrogType.section).tracking(-0.2)
                }.padding(.horizontal, 16).padding(.top, 19).padding(.bottom, 23)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { WindowDragRegion().accessibilityHidden(true) }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            SidebarFeatureList(features: model.toolkit.sidebar) { feature, marker in
                                navigationButton(featureItem(feature, marker: marker)).id(ToolkitRoute.feature(feature))
                            }
                            let pages = model.pluginPages
                            if !pages.isEmpty {
                                SectionCaption(text: "Plugins").padding(.horizontal, 9).padding(.top, 14).padding(.bottom, 4)
                                ForEach(pages) { item in
                                    navigationButton(NavigationItem(id: .plugin(item.id), title: item.name, symbol: PluginSymbol.name(item.symbol)))
                                        .id(ToolkitRoute.plugin(item.id))
                                }
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 6).minimalScrollbars()
                    }
                    // Reveals a feature opened from elsewhere, such as the command bar, by the least scrolling;
                    // a row already in view stays where it is. A window that opens on a page shows its row too.
                    .onAppear { reveal(section, in: proxy) }
                    .onChange(of: section) { _, route in reveal(route, in: proxy) }
                }
            }.padding(.top, 32).background(FrogStyle.sidebar)
            VStack(spacing: 2) { ForEach(workspaceNavigation) { navigationButton($0) } }
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 10)
            if !model.accessibilityGranted || !DictationController.microphoneGranted {
                Button {
                    model.toolkit.select(.settings); permissionsRequest.ask()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(FrogStyle.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Finish setup").font(FrogType.label).foregroundStyle(FrogStyle.ink)
                            Text(L10n.text(!model.accessibilityGranted ? "Allow Accessibility" : "Allow Microphone"))
                                .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                        }
                        Spacer(minLength: 0)
                    }.padding(10).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
                        .contentShape(RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
                }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 10)
            }
        }.background(FrogStyle.sidebar)
    }
    private func navigationButton(_ item: NavigationItem) -> some View {
        SidebarRow(item: item, selected: section == item.id) { model.toolkit.select(item.id) }
            .optionalNavigationShortcut(item.key)
    }
}

/// A sidebar page: highlighted on hover, filled with the selection colour when open.
private struct SidebarRow: View {
    let item: MainView.NavigationItem
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 18)
                Text(L10n.text(item.title)).font(selected ? FrogType.bodyMedium : FrogType.body).lineLimit(1)
                Spacer(minLength: 0)
                if let marker = item.marker {
                    Image(systemName: marker).font(.system(size: 9)).foregroundStyle(FrogStyle.muted).accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected || hovering ? FrogStyle.ink : FrogStyle.muted)
            .padding(.horizontal, 9).frame(height: FrogStyle.controlHeight)
            .frogRowHighlight(hovering: hovering, selected: selected)
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : []).help(item.title)
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
            .font(FrogType.body).foregroundStyle(FrogStyle.ink)
            .fixedSize(horizontal: false, vertical: true).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FrogStyle.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: FrogStyle.cardRadius))
    }
}
