import AppKit
import SwiftUI

enum WindowSwitcherLayout {
    static let width: CGFloat = 500
    static let rowHeight: CGFloat = 34
    static let visibleRows = 10
    static func size(windowCount: Int) -> CGSize {
        CGSize(width: width, height: 28 + 28 + 12 + CGFloat(max(1, min(visibleRows, windowCount))) * rowHeight)
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
}

struct WindowSwitcherOverlay: View {
    @ObservedObject var model: WindowSwitcherDisplay
    let choose: (UUID) -> Void
    let hover: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: model.query.isEmpty ? "rectangle.on.rectangle" : "magnifyingglass")
                Text(model.query.isEmpty ? L10n.text("Windows") : model.query).lineLimit(1)
                Spacer()
                Text("\(model.windows.count)").monospacedDigit()
            }.font(.system(size: 11)).foregroundStyle(FrogStyle.muted).padding(.horizontal, 12).frame(height: 28)
            Divider().opacity(0.5)
            if model.loading {
                Spacer(); ProgressView("Finding windows…").controlSize(.small); Spacer()
            } else if model.windows.isEmpty {
                Spacer()
                Text(L10n.text(model.query.isEmpty ? "No accessible windows" : "No matching windows")).font(.system(size: 14, weight: .medium))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.windows) { window in
                                Button { choose(window.id) } label: {
                                    HStack(spacing: 9) {
                                        if let icon = model.icons[window.pid] {
                                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                        } else { Image(systemName: "app").frame(width: 20, height: 20) }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(window.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(window.appName).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                         if window.minimized || window.hidden {
                                             Image(systemName: window.minimized ? "minus.rectangle" : "eye.slash")
                                                 .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                                 .help(window.minimized ? "Minimized" : "Hidden")
                                        }
                                        if let shortcut = model.shortcuts[window.pid] { Text(shortcut).font(.system(size: 10)).foregroundStyle(.secondary) }
                                         Image(systemName: "return").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                             .opacity(model.selected == window.id ? 1 : 0)
                                     }.padding(.horizontal, 8).frame(height: WindowSwitcherLayout.rowHeight)
                                         .background(model.selected == window.id ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(window.id)
                                    .onContinuousHover { phase in if case .active = phase { hover(window.id) } }
                                    .accessibilityAddTraits(model.selected == window.id ? .isSelected : [])
                            }
                        }.padding(5).minimalScrollbars()
                    }
                    .onChange(of: model.selected) { _, id in if let id, !model.selectionFromPointer { proxy.scrollTo(id) } }
                    .onAppear { if let id = model.selected { proxy.scrollTo(id) } }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("⇥ Next")
                Text("esc Cancel")
                Text("Type to search")
                Spacer()
                Text("Release ⌘ to switch")
            }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted).padding(.horizontal, 12).frame(height: 28)
        }.frame(width: WindowSwitcherLayout.width)
            .environment(\.locale, L10n.locale)
            .frogPanel()
            .foregroundStyle(FrogStyle.ink)
    }
}
