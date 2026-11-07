import AppKit
import SwiftUI

enum WindowSwitcherLayout {
    static let width: CGFloat = 500
    static let rowHeight: CGFloat = 44
    static let queryLineHeight: CGFloat = 44
    static let visibleRows = 10
    /// The footer that says typing searches and what Return does, as every Frog panel has.
    static let footerHeight: CGFloat = 32
    /// The panel fits up to ten rows, at least one for the empty message, the search line while there is a query,
    /// and the footer.
    static func size(windowCount: Int, queryVisible: Bool = false) -> CGSize {
        CGSize(width: width, height: 2 * FrogStyle.panelInset + CGFloat(max(1, min(visibleRows, windowCount))) * rowHeight
               + (queryVisible ? queryLineHeight : 0) + footerHeight)
    }
    /// The icon a window shows while its app's own is not read yet: macOS's generic application icon, never a blank square.
    @MainActor static let genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)
}

@MainActor
final class WindowSwitcherDisplay: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selected: UUID?
    @Published var loading = false
    @Published var query = ""
    @Published var icons: [pid_t: NSImage] = [:]
    @Published var shortcuts: [pid_t: String] = [:]
    var selectionFromPointer = false

    func preload(_ snapshot: WindowCatalog.Snapshot, in panel: NSPanel?) {
        guard panel?.isVisible != true, windows != snapshot.windows else { return }
        windows = snapshot.windows
        selected = snapshot.current
        loading = false
        // Build the first visible rows during idle inventory refresh, rather than
        // on the first Command–Tab. Subsequent selections reuse the hosted tree.
        panel?.setContentSize(WindowSwitcherLayout.size(windowCount: windows.count, queryVisible: false))
        panel?.contentView?.layoutSubtreeIfNeeded()
    }
}

struct WindowSwitcherOverlay: View {
    @ObservedObject var model: WindowSwitcherDisplay
    let choose: (UUID) -> Void
    let hover: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !model.query.isEmpty { queryLine }
            if model.windows.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? L10n.text("No accessible windows") : "No windows match \"\(model.query)\"").font(FrogType.row).foregroundStyle(FrogStyle.muted)
                    .lineLimit(1).truncationMode(.middle).padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.windows) { window in
                                Button { choose(window.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(nsImage: model.icons[window.pid] ?? WindowSwitcherLayout.genericIcon).resizable()
                                            .frame(width: 28, height: 28)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(window.title).font(FrogType.row).lineLimit(1)
                                            Text(window.appName).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        if window.minimized || window.hidden {
                                            StateBadge(title: window.minimized ? "Minimized" : "Hidden",
                                                       symbol: window.minimized ? "arrow.down.right.and.arrow.up.left" : "eye.slash")
                                        }
                                        if let shortcut = model.shortcuts[window.pid] { KeyCaps(shortcut) }
                                    }.padding(.horizontal, 10).frame(height: WindowSwitcherLayout.rowHeight)
                                        // The pointer moves the selection here, so the selection is the only highlight.
                                        .frogRowHighlight(hovering: false, selected: model.selected == window.id)
                                }.buttonStyle(.plain).id(window.id)
                                    .onContinuousHover { phase in if case .active = phase { hover(window.id) } }
                                    .accessibilityAddTraits(model.selected == window.id ? .isSelected : [])
                            }
                        }.padding(FrogStyle.panelInset)
                    }
                    // `.never`, not `.hidden`: with "Show scroll bars: Always" macOS shows a hidden indicator anyway.
                    .scrollIndicators(.never)
                    .onChange(of: model.selected) { _, id in if let id, !model.selectionFromPointer { proxy.scrollTo(id) } }
                    .onAppear { if let id = model.selected { proxy.scrollTo(id) } }
                }
            }
            PanelFooter(symbol: WindowSwitcherPlugin.info.symbol, name: WindowSwitcherPlugin.info.name,
                        // The search line appears only once typing starts, so until then the footer says it is there.
                        detail: model.query.isEmpty ? L10n.text("Type to search") : model.windows.count == 1 ? L10n.text("1 window")
                            : String(format: L10n.text("%d windows"), model.windows.count),
                        primaryTitle: model.windows.isEmpty ? nil : "Switch", showsActions: false, closeTitle: "Close")
        }.frame(width: WindowSwitcherLayout.width)
            .environment(\.locale, L10n.locale)
            .frogPanel()
            .foregroundStyle(FrogStyle.ink)
            .environment(\.frogKeyboardSurface, true)
    }

    /// A window's state in words, so minimized and hidden need no legend.
    private struct StateBadge: View {
        let title: String
        let symbol: String
        var body: some View {
            Label(L10n.text(title), systemImage: symbol).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                .labelStyle(.titleAndIcon).padding(.horizontal, FrogStyle.space6).frame(height: 18)
                .background(FrogStyle.control, in: Capsule())
        }
    }

    /// What has been typed to narrow the list; Backspace takes it back a character at a time.
    private var queryLine: some View {
        // The magnifier as wide as a row icon, so the query starts where the window titles do.
        HStack(spacing: FrogStyle.space12) {
            Image(systemName: "magnifyingglass").font(FrogType.row).foregroundStyle(FrogStyle.muted).frame(width: 28)
            Text(model.query).font(FrogType.row).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            KeyCap("⌫")
        }.padding(.horizontal, FrogStyle.space10).frame(height: WindowSwitcherLayout.queryLineHeight - FrogStyle.space12)
            .frogControlSurface(height: WindowSwitcherLayout.queryLineHeight - FrogStyle.space12, radius: FrogStyle.controlRadius)
            .padding(.horizontal, FrogStyle.panelInset).padding(.top, FrogStyle.panelInset).frame(height: WindowSwitcherLayout.queryLineHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Search"))
            .accessibilityValue(model.query)
    }
}
