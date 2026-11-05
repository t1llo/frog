import AppKit
import SwiftUI
import FrogCore

struct FrogMenuLabel: View {
    @ObservedObject var power: StayAwakeController
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: FrogMenuIcon.image).renderingMode(.template)
            if power.isEnabled && !power.hasOwnMenuBarIcon { Image(systemName: "cup.and.saucer.fill").font(.system(size: 11)) }
        }.accessibilityLabel(power.isEnabled ? "Frog, stay awake on" : "Frog")
    }
}

/// The Frog menu-bar popup: Frog's own rows and the rows plugins add, with a tab for each plugin that adds one,
/// such as System or Usage.
struct FrogStatusMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = Self.frogTab

    static let popupName = "Frog"
    private static let frogTab = "frog"

    var body: some View {
        let host = model.pluginHost
        let tabs = host.menuTabs
        let shown = tabs.contains { $0.id == selectedTab } ? selectedTab : Self.frogTab
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FrogStyle.space8) {
                Image(nsImage: FrogMenuIcon.image).renderingMode(.template)
                // With tabs, the first tab names Frog.
                if tabs.isEmpty { Text("Frog").font(FrogType.section) }
                Spacer()
                if !tabs.isEmpty {
                    CompactSegments(values: [Self.frogTab] + tabs.map(\.id), selected: shown,
                                    width: min(232, CGFloat(64 * (tabs.count + 1))), compact: true,
                                    title: { id in tabs.first { $0.id == id }?.tabTitle ?? "Frog" }) { selectedTab = $0 }
                        .accessibilityElement(children: .contain).accessibilityLabel("Menu view")
                }
            }.padding(.horizontal, FrogStyle.space6).frame(height: 40)

            VStack(alignment: .leading, spacing: FrogStyle.space8) {
                if let tab = tabs.first(where: { $0.id == shown }) {
                    tab.content()
                } else {
                    VStack(alignment: .leading, spacing: FrogStyle.space2) {
                        ForEach(host.menuRows) { $0.content() }
                        if model.isProcessing {
                            action("Cancel processing", symbol: "xmark", tint: FrogStyle.critical) { model.cancelProcessing() }
                        }
                    }.padding(FrogStyle.listInset).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
                    if let error = model.errorMessage {
                        HStack(alignment: .top) {
                            Text(String(error.prefix(500))).font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                                .lineLimit(3).help("Full details are in Settings → Errors.")
                            Spacer(minLength: 0)
                            IconAction(title: "Dismiss error", symbol: "xmark", action: model.dismissError)
                        }.padding(FrogStyle.rowPadding).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
                    }
                }
                VStack(alignment: .leading, spacing: FrogStyle.space2) {
                    UpdateReadyRow { dismiss(); UpdateService.shared.installReadyUpdate() }
                    action(model.setupPresented ? "Set up Frog…" : "Open Frog", symbol: "arrow.up.forward.app", key: "⌘,",
                           tint: FrogStyle.accent) {
                        dismiss(); model.showSettings()
                    }.keyboardShortcut(",")
                    action("Quit Frog", symbol: "power", key: "⌘Q") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                }.padding(FrogStyle.listInset).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
            }
        }.padding(FrogStyle.space8).frame(width: 292).fixedSize(horizontal: false, vertical: true)
            .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
            .frogPanel()
            .background(MenuWindowSizing())
            .task { model.refreshSystemStatus() }
            .onAppear { NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: Self.popupName) }
            .onReceive(NotificationCenter.default.publisher(for: .frogMenuPopupWillOpen)) { note in
                if note.object as? String != Self.popupName { dismiss() }
            }
    }

    private func action(_ title: String, symbol: String, key: String? = nil, tint: Color = FrogStyle.muted,
                        perform: @escaping () -> Void) -> some View {
        MenuActionRow(title: title, symbol: symbol, key: key, tint: tint, action: perform)
    }
}

/// The organizer takes its arrow out of the menu bar when it cannot run, so this menu says why.
struct MenuBarOrganizerNotice: View {
    @ObservedObject var organizer: MenuBarOrganizer
    var body: some View {
        if let notice = organizer.menuNotice {
            HStack(alignment: .top) {
                Text(notice).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    .lineLimit(3).help("Open Hidden bar for details.")
                Spacer(minLength: 0)
            }.padding(FrogStyle.rowPadding)
        }
    }
}

/// Frog's two menu-bar popups open one at a time; opening one asks the other to close.
extension Notification.Name {
    static let frogMenuPopupWillOpen = Notification.Name("xyz.beffa.frog.menuPopupWillOpen")
}

/// Phone at a glance: a green dot while the phone is connected, and the way to its page.
struct PhoneMenuRow: View {
    @ObservedObject var phone: PhoneController
    let open: () -> Void
    var body: some View {
        let connected = phone.overall != .offline
        MenuActionRow(title: "Phone", symbol: connected ? "iphone" : "iphone.slash",
                      key: L10n.text(phone.statusText), dot: connected ? FrogStyle.good : nil,
                      tint: connected ? FrogStyle.good : FrogStyle.muted, closes: true, action: open)
    }
}

/// A full-width command row shared by the menu-bar popups.
struct MenuActionRow: View {
    let title: String
    let symbol: String
    var key: String? = nil
    /// A status dot before `key`, such as green for a connected phone.
    var dot: Color? = nil
    /// The colour of the icon tile; neutral unless the row has a meaning of its own.
    var tint: Color = FrogStyle.muted
    /// Closes the popup first, for rows that open something else.
    var closes = false
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { if closes { dismiss() }; action() } label: {
            HStack(spacing: FrogStyle.space10) {
                PluginIconTile(symbol: symbol, tint: tint, size: .sidebar)
                Text(L10n.text(title)).font(FrogType.row)
                Spacer()
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                if let key { Text(key).font(FrogType.small).foregroundStyle(FrogStyle.muted) }
            }.padding(.horizontal, FrogStyle.rowPadding).frame(height: FrogStyle.rowHeight - 8).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}

/// Menu rows highlight like list rows: a neutral fill on hover, the control radius.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        Row(configuration: configuration)
    }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label.frogRowHighlight(hovering: hovering || configuration.isPressed).onHover { hovering = $0 }
        }
    }
}
