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
    static let frogTab = "frog"

    /// `tab` opens the popup on a plugin's tab rather than Frog's own, for pictures of each tab.
    init(model: AppModel, tab: String = Self.frogTab) {
        self.model = model
        _selectedTab = State(initialValue: tab)
    }

    var body: some View {
        let host = model.pluginHost
        let tabs = host.menuTabs
        let shown = tabs.contains { $0.id == selectedTab } ? selectedTab : Self.frogTab
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header(tabs: tabs, shown: shown)
                VStack(alignment: .leading, spacing: FrogStyle.panelCardGap) {
                    if let tab = tabs.first(where: { $0.id == shown }) {
                        // A tab's own views observe their own models, so an unrelated AppModel change need not rebuild them.
                        MenuTabBody(id: tab.id, build: tab.content).equatable()
                    } else {
                        frogContent(host.menuRows)
                    }
                }
            }
            // Cards sit their inset in from the panel's sides and top, and 8 above the footer band, as in every popup.
            .padding([.horizontal, .top], FrogStyle.panelCardInset).padding(.bottom, FrogStyle.space8)
            footer(status: tabs.first(where: { $0.id == shown })?.status, frog: shown == Self.frogTab)
        }.frame(width: StatusItemPopup.width).fixedSize(horizontal: false, vertical: true)
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
        }
        // On the popup header's edge: the logo sits where FrogPopupHeader's tile and the rows' tiles do.
        .padding(.leading, FrogStyle.cardPadding).padding(.trailing, FrogStyle.space6).frame(height: 40)
    }

    /// The plugins' rows in a card, and an error when there is one.
    @ViewBuilder private func frogContent(_ rows: [MenuContribution]) -> some View {
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

    /// Processing, Needs attention or Setup not finished; nothing while Frog is simply ready.
    private var status: (text: String, color: Color)? {
        model.isProcessing ? ("Processing", FrogStyle.accent)
            : model.errorMessage != nil ? ("Needs attention", FrogStyle.warning)
            : model.setupPresented ? ("Setup not finished", FrogStyle.warning) : nil
    }

    /// The footer every popup has: the open tab's status on the leading side (Frog's own state on Frog's tab), and
    /// Settings and Quit with their keys on the trailing side.
    private func footer(status tabStatus: (@MainActor () -> AnyView)?, frog: Bool) -> some View {
        FrogFooter {
            if let tabStatus { tabStatus() }
            else if frog {
                let state = status ?? ("Ready", FrogStyle.good)
                Circle().fill(state.color).frame(width: 6, height: 6)
                Text(L10n.text(state.text))
            }
        } actions: {
            FrogFooterHint(model.setupPresented ? "Set up Frog" : "Settings", keys: "\u{2318},") {
                dismiss(); model.showSettings()
            }.keyboardShortcut(",")
            FrogFooterHint("Quit", keys: "\u{2318}Q") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
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
        // The feature's own green tile in every state, as in the sidebar and the command bar; the dot and the
        // status word say whether a phone is connected.
        MenuActionRow(title: "Phone", symbol: PhonePlugin.info.symbol,
                      key: L10n.text(phone.statusText), dot: connected ? FrogStyle.good : nil,
                      tint: PhonePlugin.info.tint.color, closes: true, opensPage: true, action: open)
    }
}

/// Stay awake in Frog's popup, set like the command rows beside it: the feature's tile and name, then how long while
/// it is off or until when while it is on, and its switch.
struct StayAwakeMenuRow: View {
    @ObservedObject var power: StayAwakeController
    let choose: (StayAwakeController.DurationChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space2) {
            HStack(spacing: FrogStyle.space10) {
                PluginIconTile(symbol: power.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer", tint: StayAwakePlugin.info.tint.color, size: .sidebar)
                // Truncates rather than pushing the controls out where a translation runs long.
                Text(L10n.text("Stay awake")).font(FrogType.row).lineLimit(1)
                Spacer(minLength: FrogStyle.space6)
                if power.isEnabled {
                    Text(power.deadline.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Until turned off")
                        .font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                } else {
                    FrogDropdown(selected: power.duration, options: StayAwakeController.DurationChoice.allCases, width: 96, compact: true,
                                 title: { L10n.text($0 == .untilTime ? "Until \(StayAwakePage.title(of: power.untilTime))" : $0.title) },
                                 choose: choose)
                        .accessibilityLabel("Stay-awake duration")
                }
                Toggle("Stay awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                    .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                    .accessibilityHint("Keep this Mac awake")
                    // While a change is under way the spinner takes the switch's place, so the row needs no extra width.
                    .opacity(power.isBusy ? 0 : 1)
                    .overlay { if power.isBusy { FrogSpinner(size: .mini) } }
                    // Apart from the duration, so the two controls read as two, not one crowded cluster.
                    .padding(.leading, FrogStyle.space6)
            }
            // The switch ends where the command rows' keys do, `rowPadding` in.
            .padding(.horizontal, FrogStyle.rowPadding).frame(height: FrogStyle.menuRowHeight)
            if let message = power.error ?? power.notice {
                Text(String(message.prefix(300))).font(FrogType.caption)
                    .foregroundStyle(power.error == nil ? FrogStyle.muted : FrogStyle.warning).lineLimit(2)
                    .padding(.horizontal, FrogStyle.rowPadding).padding(.bottom, FrogStyle.space6)
                    .help("Open Stay awake for details.")
            }
        }
        .task { await power.refresh() }
    }
}

/// A full-width command row shared by the menu-bar popups.
struct MenuActionRow: View {
    let title: String
    let symbol: String
    var key: String? = nil
    /// The keys that run it, drawn as caps, one per key.
    var shortcut: String? = nil
    /// A status dot before `key`, such as green for a connected phone.
    var dot: Color? = nil
    /// The colour of the icon tile: the feature's own colour, or a fixed grey that reads the same in light and dark.
    var tint: Color = PluginTint.gray.color
    /// Closes the popup first, for rows that open something else.
    var closes = false
    /// Opens a page of Frog's window: a chevron ends the row, so a row without keys still reads as one that goes
    /// somewhere.
    var opensPage = false
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
                if let shortcut, !shortcut.isEmpty { KeyCaps(shortcut) }
                if opensPage {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(FrogStyle.muted)
                        .accessibilityHidden(true)
                }
            }.padding(.horizontal, FrogStyle.rowPadding).frame(height: FrogStyle.menuRowHeight).contentShape(Rectangle())
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
