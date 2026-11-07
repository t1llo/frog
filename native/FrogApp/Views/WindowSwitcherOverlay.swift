import AppKit
import SwiftUI

/// The window switcher in the panel family's frame: the family's width, the same search line and footer, and as many
/// rows as there are windows up to the family's height.
enum WindowSwitcherLayout {
    static let width = FloatingPanelLayout.width
    static let rowHeight: CGFloat = 44
    static let footerHeight = FloatingPanelLayout.footerHeight
    static let visibleRows = Int((FloatingPanelLayout.height - FloatingPanelLayout.chromeHeight) / rowHeight)
    /// The search line, up to `visibleRows` rows (at least one, for the empty message), and the footer.
    static func size(windowCount: Int) -> CGSize {
        CGSize(width: width, height: FloatingPanelLayout.chromeHeight + CGFloat(max(1, min(visibleRows, windowCount))) * rowHeight)
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
        panel?.setContentSize(WindowSwitcherLayout.size(windowCount: windows.count))
        panel?.contentView?.layoutSubtreeIfNeeded()
    }
}

struct WindowSwitcherOverlay: View {
    @ObservedObject var model: WindowSwitcherDisplay
    let choose: (UUID) -> Void
    let hover: (UUID) -> Void
    var placement = PanelFamilyPlacer()

    var body: some View {
        VStack(spacing: 0) {
            searchLine
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
                        }.padding(.horizontal, FrogStyle.panelInset).padding(.top, FrogStyle.space2).padding(.bottom, FrogStyle.panelInset)
                    }
                    // `.never`, not `.hidden`: with "Show scroll bars: Always" macOS shows a hidden indicator anyway.
                    .scrollIndicators(.never)
                    .onChange(of: model.selected) { _, id in if let id, !model.selectionFromPointer { proxy.scrollTo(id) } }
                    .onAppear { if let id = model.selected { proxy.scrollTo(id) } }
                }
            }
            PanelFooter(symbol: WindowSwitcherPlugin.info.symbol, name: WindowSwitcherPlugin.info.name,
                        detail: model.windows.count == 1 ? L10n.text("1 window") : String(format: L10n.text("%d windows"), model.windows.count),
                        primaryTitle: model.windows.isEmpty ? nil : "Switch", showsActions: false, closeTitle: "Close")
                .panelFamilyDragHandle(placement)
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

    /// The search line, as on the command bar and clipboard: the panel never takes the keyboard (the held shortcut
    /// keeps the app in front), so what is typed while it is held is drawn here as text, and Backspace takes it back.
    private var searchLine: some View {
        FloatingPanelSearchLine(placement: placement, iconColumn: 28, spacing: FrogStyle.space12) {
            Text(model.query.isEmpty ? L10n.text("Type to search windows") : model.query).font(FrogType.query)
                .foregroundStyle(model.query.isEmpty ? FrogStyle.placeholder : FrogStyle.ink)
                .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
        } trailing: {
            if !model.query.isEmpty { KeyCap("⌫") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Search"))
        .accessibilityValue(model.query)
    }
}
