import AppKit
import SwiftUI

@MainActor
final class WindowSwitcherDisplay: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selected: UUID?
    @Published var loading = false
    @Published var icons: [pid_t: NSImage] = [:]
}

struct WindowSwitcherOverlay: View {
    @ObservedObject var model: WindowSwitcherDisplay
    let choose: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "macwindow.on.rectangle").foregroundStyle(FrogStyle.accent)
                Text("Windows").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(model.windows.count)").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(18)
            Divider()
            if model.loading {
                Spacer(); ProgressView("Finding windows…").controlSize(.small); Spacer()
            } else if model.windows.isEmpty {
                Spacer()
                Text("No accessible windows").font(.system(size: 14, weight: .medium))
                Text("Open a window, then try again.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.windows) { window in
                                Button { choose(window.id) } label: {
                                    HStack(spacing: 12) {
                                        if let icon = model.icons[window.pid] {
                                            Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                                        } else { Image(systemName: "app").frame(width: 30, height: 30) }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(window.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(window.appName).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        if window.minimized || window.hidden {
                                            Text(window.minimized ? "Minimized" : "Hidden").font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        if model.selected == window.id { Image(systemName: "return").font(.system(size: 12)).foregroundStyle(FrogStyle.accent) }
                                    }.padding(.horizontal, 12).padding(.vertical, 10)
                                        .background(model.selected == window.id ? FrogStyle.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(window.id)
                                    .accessibilityAddTraits(model.selected == window.id ? .isSelected : [])
                            }
                        }.padding(8)
                    }
                    .onChange(of: model.selected) { _, id in if let id { proxy.scrollTo(id) } }
                    .onAppear { if let id = model.selected { proxy.scrollTo(id) } }
                }
            }
            Divider()
            HStack(spacing: 18) {
                Text("⇥ Next")
                Text("⇧⇥ Previous")
                Text("esc Cancel")
                Spacer()
                Text("Release ⌘ to switch")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(14)
        }.frame(width: 580, height: 480)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .foregroundStyle(FrogStyle.ink).preferredColorScheme(.dark)
    }
}
