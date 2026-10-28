import AppKit
import SwiftUI

enum WindowSwitcherLayout {
    static let width: CGFloat = 500
    static let rowHeight: CGFloat = 34
    static let queryLineHeight: CGFloat = 30
    static let visibleRows = 10
    /// The panel fits up to ten rows, at least one for the empty message, and the search line while there is a query.
    static func size(windowCount: Int, queryVisible: Bool = false) -> CGSize {
        CGSize(width: width, height: 12 + CGFloat(max(1, min(visibleRows, windowCount))) * rowHeight + (queryVisible ? queryLineHeight : 0))
    }
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
                Text(model.query.isEmpty ? L10n.text("No accessible windows") : "No windows match \"\(model.query)\"").font(FrogType.section)
                    .lineLimit(1).truncationMode(.middle).padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.windows) { window in
                                Button { choose(window.id) } label: {
                                    HStack(spacing: 12) {
                                        if let icon = model.icons[window.pid] {
                                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                        } else { Image(systemName: "app").frame(width: 20, height: 20) }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(window.title).font(FrogType.body).lineLimit(1)
                                            Text(window.appName).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        if window.minimized || window.hidden {
                                            Image(systemName: window.minimized ? "minus.rectangle" : "eye.slash")
                                                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                                .help(window.minimized ? "Minimized" : "Hidden")
                                        }
                                        if let shortcut = model.shortcuts[window.pid] { Text(shortcut).font(FrogType.caption).foregroundStyle(FrogStyle.muted) }
                                        Image(systemName: "return").font(.system(size: 11, weight: .medium)).foregroundStyle(FrogStyle.accent)
                                            .opacity(model.selected == window.id ? 1 : 0)
                                    }.padding(.horizontal, 8).frame(height: WindowSwitcherLayout.rowHeight)
                                        // The pointer moves the selection here, so the selection is the only highlight.
                                        .frogRowHighlight(hovering: false, selected: model.selected == window.id)
                                }.buttonStyle(.plain).id(window.id)
                                    .onContinuousHover { phase in if case .active = phase { hover(window.id) } }
                                    .accessibilityAddTraits(model.selected == window.id ? .isSelected : [])
                            }
                        }.padding(6)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.selected) { _, id in if let id, !model.selectionFromPointer { proxy.scrollTo(id) } }
                    .onAppear { if let id = model.selected { proxy.scrollTo(id) } }
                }
            }
        }.frame(width: WindowSwitcherLayout.width)
            .environment(\.locale, L10n.locale)
            .frogPanel()
            .foregroundStyle(FrogStyle.ink)
            .environment(\.frogKeyboardSurface, true)
    }

    /// What has been typed to narrow the list; Backspace takes it back a character at a time.
    private var queryLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(FrogType.body).foregroundStyle(FrogStyle.muted)
            Text(model.query).font(FrogType.body).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            KeyCap("⌫")
        }.padding(.horizontal, 14).frame(height: WindowSwitcherLayout.queryLineHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Search"))
            .accessibilityValue(model.query)
    }
}
