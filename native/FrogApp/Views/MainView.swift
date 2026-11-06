import SwiftUI
import AppKit
import FrogCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var section: ToolkitRoute { model.toolkit.route }
    @State private var permissionsRequest = ScrollRequest()
    /// What the sidebar's search field narrows its rows to.
    @State private var sidebarQuery = ""
    /// The title the open page's header hands up, shown in the toolbar.
    @State private var pageTitle: String?
    /// The one-line subtitle the open page's header hands up, shown under the title.
    @State private var pageSubtitle: String?
    /// How wide the open page's column grows, so the toolbar's actions end where its cards do.
    @State private var pageWidth = FrogStyle.pageWidth
    /// Pages visited before and after the open one, for back and forward.
    @State private var history = PageHistory()
    /// A step back inside the open page, which Back takes first.
    @State private var pageBack: FrogPageBack?
    /// Draws this in place of the open route's page, for pictures of a step or tab inside a page (a History entry,
    /// a Models tab) in the whole window. The sidebar still shows the route.
    var pageOverride: AnyView? = nil

    fileprivate struct NavigationItem: Identifiable {
        let id: ToolkitRoute
        let title: String
        let symbol: String
        var tint: Color?
        var key: KeyEquivalent?
    }
    private var workspaceNavigation: [NavigationItem] {
        [NavigationItem(id: .models, title: "Models", symbol: "cpu", tint: PluginTint.indigo.color),
         NavigationItem(id: .features, title: "Features", symbol: "square.grid.2x2", tint: PluginTint.green.color),
         NavigationItem(id: .settings, title: "Settings", symbol: "gearshape.fill", tint: PluginTint.gray.color, key: ",")]
    }
    /// The page of a built-in plugin; History keeps its own route until navigation moves to plugin IDs.
    static func route(for plugin: String) -> ToolkitRoute {
        if plugin == "history" { return .history }
        return BuiltinPlugins.legacyFeatures[plugin].map { .feature($0) } ?? .features
    }
    @ViewBuilder private func pluginPage(_ id: String) -> some View {
        if let page = model.pluginHost.page(for: id) { page }
        else if let descriptor = model.pluginHost.descriptor(id) {
            FrogEmptyState(symbol: descriptor.info.symbol, title: "\(descriptor.info.name) is off",
                           message: "Turn it on in Features.", tint: descriptor.info.tint)
        }
    }
    @ViewBuilder private var selectedPage: some View {
        if let pageOverride { pageOverride } else { routePage }
    }
    @ViewBuilder private var routePage: some View {
        switch section {
        case .history: pluginPage("history")
        case .models: ProvidersView()
        case .features: PluginsCatalogView()
        case .settings: PreferencesView(permissionsRequest: $permissionsRequest)
        // Statistics is a step inside Settings: the toolbar's breadcrumb leads back, so the page draws no link.
        case .statistics:
            StatisticsView(statistics: model.statistics)
                .frogPageBack("statistics", parent: "Settings") { model.toolkit.select(.settings) }
        case .plugin(let id): PluginPageView(id: id)
        case .feature(let feature): pluginPage(BuiltinPlugins.pluginID(for: feature))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
                .padding([.top, .leading, .bottom], FrogStyle.sidebarInset)
            VStack(spacing: 0) {
                // Room for the toolbar, which is drawn over the page so its content scrolls up beneath it.
                Color.clear.frame(height: FrogStyle.toolbarHeight)
                selectedPage.id(section).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.frogToolbarTitle, true)
                    .onPreferenceChange(FrogPageTitleKey.self) { pageTitle = $0 }
                    .onPreferenceChange(FrogPageSubtitleKey.self) { pageSubtitle = $0 }
                    .onPreferenceChange(FrogPageWidthKey.self) { pageWidth = $0 ?? FrogStyle.pageWidth }
                    .onPreferenceChange(FrogPageBackKey.self) { pageBack = $0 }
                // Errors are occasional: the banner rises into place (fades with Reduce Motion) and leaves a little faster.
                // The page beside it does not animate.
                VStack(spacing: 0) {
                    if let error = model.errorMessage {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(FrogStyle.critical)
                            Text(error).font(FrogType.body).textSelection(.enabled)
                                .lineLimit(3).help("Full details are in Settings → Errors.")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            CopyAction(title: "Copy error") { ViewActions.copy(error) }
                            IconAction(title: "Dismiss error", symbol: "xmark", action: model.dismissError)
                        }.padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
                            .background(FrogStyle.critical.opacity(0.08), in: RoundedRectangle(cornerRadius: FrogStyle.cardRadius))
                            .padding(.horizontal, FrogStyle.pagePadding).padding(.bottom, FrogStyle.space16)
                            .transition(.asymmetric(insertion: reduceMotion ? .opacity : .offset(y: 8).combined(with: .opacity), removal: .opacity))
                    }
                }.animation(model.errorMessage == nil ? FrogMotion.exit : FrogMotion.reveal, value: model.errorMessage)
            }
            // The page's header actions are views, so they come up as a preference read here rather than state.
            .overlayPreferenceValue(FrogPageActionsKey.self, alignment: .top) { toolbar(actions: $0?.view) }
            .clipped()
                .sheet(item: Binding(get: { model.pluginReview }, set: { if $0 == nil { model.pluginRuntime?.dismissReview() } })) { review in
                    PluginReviewSheet(review: review, plugins: model.plugins) { model.report($0) }
                }
        }
        .font(FrogType.lead).foregroundStyle(FrogStyle.ink)
        .environment(\.locale, L10n.locale)
        .background(FrogStyle.canvas)
        .frogSurface(.window)
        .ignoresSafeArea(.container, edges: .top)
        .tint(FrogStyle.accent).buttonStyle(FrogButtonStyle())
        .frame(minWidth: 800, minHeight: 520)
        .onAppear { model.refreshSystemStatus() }
        .onChange(of: section) { previous, _ in
            history.visited(from: previous)
            // A search hides rows and their ⌘1–9; it ends once a page is open.
            sidebarQuery = ""
        }
        .sheet(isPresented: Binding(get: { model.setupPresented }, set: { if !$0 { model.finishSetup() } })) {
            OnboardingView().environmentObject(model).interactiveDismissDisabled()
        }
    }

    /// Scrolls the sidebar by the least amount that shows the open page's row; a row already in view stays put.
    /// Statistics shows Settings, the row it belongs to.
    ///
    /// It waits for the next turn of the run loop: asked while the list is still being laid out (the window opening
    /// on a page), `scrollTo` did nothing, and the open row stayed below the fold with only the top of its
    /// highlight peeking out above the pinned rows, a selection pill with no row.
    private func reveal(_ route: ToolkitRoute, in proxy: ScrollViewProxy) {
        let target = route == .statistics ? ToolkitRoute.settings : route
        DispatchQueue.main.async { proxy.scrollTo(target) }
    }

    // MARK: Toolbar

    /// The open page's header, as a Mac window shows its title: the title, with the one-line subtitle under it,
    /// on the page's content edge, and the page's actions on the trailing side, ending where the page's column
    /// does. Title and subtitle together sit level with the window's buttons. A step inside a page shows where it
    /// came from first, as a breadcrumb ("Settings › Statistics") whose first part goes back. Back and forward sit
    /// in the sidebar, beside the window's buttons. The bar drags the window.
    private func toolbar(actions: AnyView?) -> some View {
        HStack(spacing: FrogStyle.space16) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: FrogStyle.space6) {
                    if let parent = breadcrumbParent {
                        FrogBreadcrumbLink(title: parent.title, action: parent.action)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(FrogStyle.muted).accessibilityHidden(true)
                    }
                    Text(pageTitle ?? fallbackTitle).font(FrogType.pageTitle).tracking(-0.3).foregroundStyle(FrogStyle.ink)
                        .lineLimit(1).accessibilityAddTraits(.isHeader)
                }
                if let pageSubtitle {
                    Text(pageSubtitle).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        .lineLimit(1).truncationMode(.tail).help(pageSubtitle)
                }
            }
            Spacer(minLength: 0)
            // The actions keep their size; a long subtitle is the one to shorten.
            if let actions { HStack(spacing: FrogStyle.space8) { actions }.fixedSize() }
        }
        .frame(maxWidth: pageWidth, alignment: .leading)
        // Level with the window's buttons, which the 52-point title bar centres 26 points down.
        .padding(.horizontal, FrogStyle.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: FrogStyle.toolbarHeight)
        .background { WindowDragRegion().accessibilityHidden(true) }
        .background(alignment: .top) { toolbarScrim }
    }

    /// Where the open page was entered from, when it is a step inside another: the page's own step back (a
    /// History entry, or Statistics inside Settings).
    private var breadcrumbParent: (title: String, action: () -> Void)? {
        if let pageBack, let parent = pageBack.parent { return (L10n.text(parent), pageBack.action) }
        return nil
    }

    /// Back and forward, two plain chevrons at the top of the sidebar beside the window's buttons (⌘[ and ⌘]).
    /// Back takes a step inside the open page first.
    private var historyButtons: some View {
        HStack(spacing: 0) {
            HistoryButton(title: "Back", symbol: "chevron.left", enabled: pageBack != nil || history.canGoBack) {
                if let pageBack { pageBack.action() } else { travel(history.back(from: section)) }
            }
                .keyboardShortcut("[", modifiers: .command)
            HistoryButton(title: "Forward", symbol: "chevron.right", enabled: history.canGoForward) { travel(history.forward(from: section)) }
                .keyboardShortcut("]", modifiers: .command)
        }
    }

    /// Rex's veil behind the toolbar: the window's own colour, solid behind the title and buttons and fading out
    /// a little below them, so a page scrolled up beneath dissolves instead of running through the title.
    private var toolbarScrim: some View {
        Rectangle().fill(FrogStyle.canvas)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                         .init(color: .black, location: FrogStyle.toolbarHeight / (FrogStyle.toolbarHeight + FrogStyle.toolbarFade)),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .frame(height: FrogStyle.toolbarHeight + FrogStyle.toolbarFade)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func travel(_ route: ToolkitRoute?) {
        guard let route else { return }
        let before = section
        model.toolkit.select(route)
        // A page that is no longer there may leave the route as it was; then nothing moved and no change will come
        // to clear the flag. If it fell back to another page, that change is still the travel, not a new visit.
        if model.toolkit.route == before { history.cancelTravel() }
    }

    /// The title of the open page when its header has not named it, such as an empty state.
    private var fallbackTitle: String {
        switch section {
        case .models: return L10n.text("Models")
        case .features: return L10n.text("Features")
        case .settings: return L10n.text("Settings")
        case .statistics: return L10n.text("Statistics")
        case .plugin(let id): return model.pluginPages.first { $0.id == id }?.name ?? "Frog"
        case .history, .feature:
            let plugin = model.pluginHost.sidebar.flatMap(\.plugins).first { Self.route(for: $0.id) == section }
            return plugin.map { L10n.text($0.name) } ?? "Frog"
        }
    }

    // MARK: Sidebar

    /// A panel floating inside the window: search, Frog's own row for Settings, then the plugins in their
    /// groups and Community pages, which scroll, and Models, Features and Settings pinned at the bottom. Groups are
    /// set apart by space alone.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's buttons sit in this strip, centred 26 points down the window like back and forward
            // on its trailing side.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                historyButtons
            }
            .padding(.trailing, FrogStyle.sidebarRowInset)
            .frame(height: 36).frame(maxWidth: .infinity)
            .background { WindowDragRegion().accessibilityHidden(true) }
            .padding(.bottom, FrogStyle.space12)
            SearchBox(placeholder: "Search", text: $sidebarQuery)
                .padding(.horizontal, FrogStyle.sidebarRowInset).padding(.bottom, FrogStyle.space16)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        settingsRow.padding(.bottom, FrogStyle.space8)
                        let groups = model.pluginHost.sidebar
                        let numbered = groups.flatMap(\.plugins).prefix(9).map(\.id)
                        ForEach(groups, id: \.category) { group in
                            let plugins = group.plugins.filter { matches($0.name) }
                            if !plugins.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(plugins) { plugin in
                                        let route = Self.route(for: plugin.id)
                                        let index = numbered.firstIndex(of: plugin.id)
                                        navigationButton(NavigationItem(id: route, title: plugin.name, symbol: plugin.symbol, tint: plugin.tint.color,
                                                                        key: index.map { KeyEquivalent(Character(String($0 + 1))) }))
                                            .id(route)
                                    }
                                }.padding(.bottom, FrogStyle.space12)
                                    .accessibilityElement(children: .contain).accessibilityLabel(L10n.text(group.category.title))
                            }
                        }
                        let pages = model.pluginPages.filter { matches($0.name) }
                        if !pages.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(pages) { item in
                                    navigationButton(NavigationItem(id: .plugin(item.id), title: item.name, symbol: PluginSymbol.name(item.symbol), tint: PluginTint.purple.color))
                                        .id(ToolkitRoute.plugin(item.id))
                                }
                            }.padding(.bottom, FrogStyle.space12)
                                .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("Community"))
                        }
                        if !sidebarQuery.isEmpty && !anyMatch {
                            Text(L10n.text("No matches")).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                                .padding(.horizontal, FrogStyle.space8).padding(.top, FrogStyle.space4)
                        }
                    }.padding(.horizontal, FrogStyle.sidebarRowInset).padding(.bottom, FrogStyle.space10).minimalScrollbars()
                }.bottomScrollFade()
                // Reveals a feature opened from elsewhere, such as the command bar, by the least scrolling;
                // a row already in view stays where it is. A window that opens on a page shows its row too.
                .onAppear { reveal(section, in: proxy) }
                .onChange(of: section) { _, route in reveal(route, in: proxy) }
            }
            // Models, Features and Settings stay pinned under the list, so the open one is always in view and
            // Settings is always one click away, however long the plugin list grows.
            let workspace = workspaceNavigation.filter { matches($0.title) }
            if !workspace.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace) { navigationButton($0) }
                }
                .padding(.horizontal, FrogStyle.sidebarRowInset).padding(.top, FrogStyle.space4)
                .padding(.bottom, FrogStyle.sidebarRowInset)
                .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("Frog"))
            }
        }
        .background(FrogStyle.sidebar, in: RoundedRectangle(cornerRadius: FrogStyle.sidebarRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: FrogStyle.sidebarRadius, style: .continuous))
        // Rex outlines its panes with a faint light edge.
        .overlay { RoundedRectangle(cornerRadius: FrogStyle.sidebarRadius, style: .continuous).strokeBorder(FrogStyle.hairline) }
    }

    private func matches(_ title: String) -> Bool {
        let query = sidebarQuery.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || L10n.text(title).localizedCaseInsensitiveContains(query) || title.localizedCaseInsensitiveContains(query)
    }

    private var anyMatch: Bool {
        model.pluginHost.sidebar.flatMap(\.plugins).contains { matches($0.name) }
            || model.pluginPages.contains { matches($0.name) } || workspaceNavigation.contains { matches($0.title) }
    }

    /// Frog's own row at the top, like Rex's server row: its status. It opens Settings, at Permissions while one is
    /// missing. The Settings row further down is where Settings is chosen and highlighted.
    private var settingsRow: some View {
        let needsSetup = !model.accessibilityGranted || !DictationController.microphoneGranted
        let status = !needsSetup ? "Settings" : !model.accessibilityGranted ? "Allow Accessibility" : "Allow Microphone"
        return SettingsHeroRow(status: needsSetup ? status : "Ready", needsSetup: needsSetup, selected: false) {
            model.toolkit.select(.settings)
            if needsSetup { permissionsRequest.ask() }
        }
    }

    private func navigationButton(_ item: NavigationItem) -> some View {
        // Statistics is reached from Settings, so Settings stays highlighted there.
        SidebarRow(item: item, selected: section == item.id || (item.id == .settings && section == .statistics)) { model.toolkit.select(item.id) }
            .optionalNavigationShortcut(item.key)
    }
}

/// Pages visited before and after the open one. Choosing a page clears forward, as in a browser.
struct PageHistory {
    private(set) var backStack: [ToolkitRoute] = []
    private(set) var forwardStack: [ToolkitRoute] = []
    /// Set while back or forward is moving, so the move is not recorded as a new visit.
    private var travelling = false
    private static let limit = 50

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The open page changed from `previous`.
    mutating func visited(from previous: ToolkitRoute) {
        if travelling { travelling = false; return }
        backStack.append(previous)
        if backStack.count > Self.limit { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    mutating func back(from current: ToolkitRoute) -> ToolkitRoute? {
        guard let route = backStack.popLast() else { return nil }
        forwardStack.append(current)
        travelling = true
        return route
    }

    mutating func forward(from current: ToolkitRoute) -> ToolkitRoute? {
        guard let route = forwardStack.popLast() else { return nil }
        backStack.append(current)
        travelling = true
        return route
    }

    /// The page could not be opened, so nothing moved.
    mutating func cancelTravel() { travelling = false }
}

/// Back or forward: a plain chevron that fills a round hover, dimmed while there is nowhere to go.
private struct HistoryButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? (hovering ? FrogStyle.ink : FrogStyle.muted) : FrogStyle.placeholder)
                .frame(width: FrogStyle.controlHeight, height: FrogStyle.controlHeight)
                .background(hovering && enabled ? FrogStyle.hover : .clear, in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).disabled(!enabled).onHover { hovering = $0 }
            .accessibilityLabel(L10n.text(title)).help(L10n.text(title))
    }
}

/// The first part of the toolbar's breadcrumb: the page a step came from, in the title's size but muted, which
/// darkens on hover and goes back when clicked.
private struct FrogBreadcrumbLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title).font(FrogType.pageTitle).tracking(-0.3).lineLimit(1)
                .foregroundStyle(hovering ? FrogStyle.ink : FrogStyle.muted)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel(L10n.text("Back to \(title)")).help(L10n.text("Back to \(title)"))
    }
}

/// Frog's row at the top of the sidebar, drawn larger than the rest: its icon, its name and a status line.
private struct SettingsHeroRow: View {
    let status: String
    let needsSetup: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: FrogStyle.space10) {
                FrogMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Frog").font(FrogType.rowMedium).foregroundStyle(FrogStyle.ink)
                    HStack(spacing: FrogStyle.space4) {
                        if needsSetup {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(FrogStyle.warning)
                        }
                        Text(L10n.text(status)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, FrogStyle.space6).padding(.vertical, FrogStyle.space6)
            .background(selected ? FrogStyle.sidebarSelection : hovering ? FrogStyle.hover : .clear,
                        in: RoundedRectangle(cornerRadius: FrogStyle.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: FrogStyle.cardRadius, style: .continuous))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel("Frog, \(L10n.text(status))").accessibilityAddTraits(selected ? .isSelected : [])
            .help(L10n.text("Settings"))
    }
}

/// A sidebar page: its coloured icon tile and name, highlighted on hover and filled when open.
private struct SidebarRow: View {
    let item: MainView.NavigationItem
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: FrogStyle.space10) {
                if let tint = item.tint {
                    PluginIconTile(symbol: item.symbol, tint: tint, size: .sidebar)
                } else {
                    Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 20)
                }
                Text(L10n.text(item.title)).font(FrogType.row).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(FrogStyle.ink)
            .padding(.horizontal, FrogStyle.space6).frame(height: FrogStyle.sidebarRowHeight)
            .background(selected ? FrogStyle.sidebarSelection : hovering ? FrogStyle.hover : .clear,
                        in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: FrogStyle.controlRadius, style: .continuous))
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
