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
            header(tabs: tabs, shown: shown)
            VStack(alignment: .leading, spacing: FrogStyle.space8) {
                if let tab = tabs.first(where: { $0.id == shown }) {
                    // A tab's own views observe their own models, so an unrelated AppModel change need not rebuild them.
                    MenuTabBody(id: tab.id, build: tab.content).equatable()
                } else {
                    frogContent(host.menuRows)
                }
            }.padding(.bottom, FrogStyle.listInset)
            footer
        }.padding(FrogStyle.panelCardInset).frame(width: 292).fixedSize(horizontal: false, vertical: true)
            .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
            .frogPanel()
            .background(MenuWindowSizing())
            .task { model.refreshSystemStatus() }
            .onAppear { NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: Self.popupName) }
            .onReceive(NotificationCenter.default.publisher(for: .frogMenuPopupWillOpen)) { note in
                if note.object as? String != Self.popupName { dismiss() }
            }
    }

    /// The icon, then either the name of the popup or the tabs that replace it.
    private func header(tabs: [MenuContribution], shown: String) -> some View {
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
    }

    /// One muted line of state, then the plugins' rows in a card, and an error when there is one.
    @ViewBuilder private func frogContent(_ rows: [MenuContribution]) -> some View {
        statusLine
        VStack(alignment: .leading, spacing: FrogStyle.space2) {
            ForEach(rows) { $0.content() }
            if model.isProcessing {
                MenuActionRow(title: "Cancel processing", symbol: "xmark", tint: FrogStyle.critical) { model.cancelProcessing() }
            }
        }.padding(FrogStyle.listInset).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
        if let error = model.errorMessage {
            HStack(alignment: .top) {
                Text(String(error.prefix(500))).font(FrogType.small).foregroundStyle(FrogStyle.warning)
                    .lineLimit(3).help("Full details are in Settings → Errors.")
                Spacer(minLength: 0)
                IconAction(title: "Dismiss error", symbol: "xmark", action: model.dismissError)
            }.padding(FrogStyle.rowPadding).frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
        }
        UpdateReadyRow { dismiss(); UpdateService.shared.installReadyUpdate() }
    }

    private var statusLine: some View {
        let (text, color): (String, Color) = model.isProcessing ? ("Processing", FrogStyle.accent)
            : model.errorMessage != nil ? ("Needs attention", FrogStyle.warning)
            : model.setupPresented ? ("Setup not finished", FrogStyle.warning) : ("Ready", FrogStyle.good)
        return HStack(spacing: FrogStyle.space6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(L10n.text(text)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
            Spacer(minLength: 0)
        }.padding(.horizontal, FrogStyle.space6).accessibilityElement(children: .combine)
    }

    /// Secondary actions under a hairline, with their shortcuts as key caps.
    private var footer: some View {
        HStack(spacing: FrogStyle.space4) {
            footerButton(model.setupPresented ? "Set up Frog…" : "Open Frog", symbol: "arrow.up.forward.app", key: "\u{2318}", key2: ",",
                         tint: FrogStyle.accent) { dismiss(); model.showSettings() }.keyboardShortcut(",")
            Spacer(minLength: 0)
            footerButton("Quit Frog", symbol: "power", key: "\u{2318}", key2: "Q", tint: FrogStyle.muted) {
                NSApplication.shared.terminate(nil)
            }.keyboardShortcut("q")
        }.padding(.horizontal, FrogStyle.space4).padding(.top, FrogStyle.space4)
            .overlay(alignment: .top) { Rectangle().fill(FrogStyle.hairline).frame(height: 1) }
    }

    private func footerButton(_ title: String, symbol: String, key: String, key2: String, tint: Color,
                              perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: FrogStyle.space6) {
                Image(systemName: symbol).font(FrogType.label).foregroundStyle(tint)
                Text(L10n.text(title)).font(FrogType.small).lineLimit(1)
                HStack(spacing: 3) { KeyCap(key); KeyCap(key2) }
            }.padding(.horizontal, FrogStyle.space8).frame(height: FrogStyle.controlHeight).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}

/// A tab's content, rebuilt only when the tab changes: its views watch their own models.
private struct MenuTabBody: View, Equatable {
    let id: String
    let build: @MainActor () -> AnyView
    static func == (lhs: MenuTabBody, rhs: MenuTabBody) -> Bool { lhs.id == rhs.id }
    var body: some View { build() }
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
