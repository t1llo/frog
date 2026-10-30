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
            HStack(spacing: 7) {
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
            }.padding(.horizontal, 8).frame(height: 40)

            if let tab = tabs.first(where: { $0.id == shown }) {
                tab.content()
            } else {
                ForEach(host.menuRows) { $0.content() }
                if model.isProcessing { action("Cancel processing", symbol: "xmark") { model.cancelProcessing() } }
                if let error = model.errorMessage {
                    HStack(alignment: .top) {
                        Text(String(error.prefix(500))).font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                            .lineLimit(3).help("Full details are in Settings → Errors.")
                        Spacer(minLength: 0)
                        IconAction(title: "Dismiss error", symbol: "xmark", action: model.dismissError)
                    }.padding(8)
                }
            }
            UpdateReadyRow { dismiss(); UpdateService.shared.installReadyUpdate() }
            action(model.setupPresented ? "Set up Frog…" : "Open Frog", symbol: "arrow.up.forward.app", key: "⌘,") {
                dismiss(); model.showSettings()
            }.keyboardShortcut(",")
            action("Quit Frog", symbol: "power", key: "⌘Q") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }.padding(6).frame(width: 292).fixedSize(horizontal: false, vertical: true)
            .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
            .frogPanel()
            .background(MenuWindowSizing())
            .task { model.refreshSystemStatus() }
            .onAppear { NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: Self.popupName) }
            .onReceive(NotificationCenter.default.publisher(for: .frogMenuPopupWillOpen)) { note in
                if note.object as? String != Self.popupName { dismiss() }
            }
    }

    private func action(_ title: String, symbol: String, key: String? = nil, perform: @escaping () -> Void) -> some View {
        MenuActionRow(title: title, symbol: symbol, key: key, action: perform)
    }
}

/// Stay awake in the popup: the duration is chosen before switching on; while on, its place shows when the session ends.
struct StayAwakeMenuRow: View {
    @ObservedObject var power: StayAwakeController
    @Environment(\.dismiss) private var dismiss
    @State private var choosingDuration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("Stay awake", systemImage: power.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(FrogType.bodyMedium).fixedSize()
                Spacer(minLength: 0)
                if power.isBusy { ProgressView().controlSize(.mini) }
                if !power.hasReadState {
                    Text("Checking…").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                } else if power.isEnabled {
                    Text(power.deadline.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? (power.ownsSession ? "Until Frog quits" : "On outside Frog"))
                        .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                } else {
                    Button { choosingDuration.toggle() } label: {
                        CompactDropdownLabel(value: L10n.text(power.duration.title), width: 98, height: FrogStyle.compactHeight)
                    }.buttonStyle(.plain).disabled(power.isBusy)
                        .accessibilityLabel("Stay-awake duration").accessibilityValue(power.duration.title)
                }
                Toggle("Stay awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                    .labelsHidden().toggleStyle(.switch).disabled(!power.canSwitch)
                    .accessibilityHint("Keep this Mac and its screen awake")
            }.frame(height: FrogStyle.compactHeight)
            if choosingDuration && !power.isEnabled {
                VStack(spacing: 1) {
                    ForEach(StayAwakeController.DurationChoice.allCases) { duration in
                        Button { power.duration = duration; choosingDuration = false } label: {
                            HStack {
                                Text(L10n.text(duration.title))
                                Spacer()
                                if power.duration == duration {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(FrogStyle.accent)
                                }
                            }.font(FrogType.small).padding(.horizontal, 8).frame(height: FrogStyle.compactHeight).contentShape(Rectangle())
                        }.buttonStyle(MenuRowStyle()).accessibilityAddTraits(power.duration == duration ? .isSelected : [])
                    }
                }
            }
            if let error = power.error {
                Text(String(error.prefix(500))).font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                    .lineLimit(3).help("Open Stay awake for details.")
            } else if let notice = power.notice {
                Text(String(notice.prefix(500))).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(3)
            }
            if power.isConfiguringAccess {
                Text("Finish in Terminal…").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
            } else if power.accessState != .ready && power.accessState != .checking {
                HStack {
                    Text(power.accessState.title).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    Spacer()
                    Button("Set up access…") { power.configureAccess(); dismiss() }.buttonStyle(.frog(compact: true))
                }
            }
        }.padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            .padding(.horizontal, 2).padding(.bottom, 4)
            .task { await power.refresh(); await power.refreshAccessUnlessReady() }
            .onChange(of: power.isEnabled) { _, _ in choosingDuration = false }
    }
}

/// The organizer takes its arrow out of the menu bar when it cannot run, so this menu says why.
struct MenuBarOrganizerNotice: View {
    @ObservedObject var organizer: MenuBarOrganizer
    var body: some View {
        if let notice = organizer.menuNotice {
            HStack(alignment: .top) {
                Text(notice).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                    .lineLimit(3).help("Open Menu bar for details.")
                Spacer(minLength: 0)
            }.padding(8)
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
                      key: L10n.text(phone.statusText), dot: connected ? FrogStyle.good : nil, closes: true, action: open)
    }
}

/// A full-width command row shared by the menu-bar popups.
struct MenuActionRow: View {
    let title: String
    let symbol: String
    var key: String? = nil
    /// A status dot before `key`, such as green for a connected phone.
    var dot: Color? = nil
    /// Closes the popup first, for rows that open something else.
    var closes = false
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { if closes { dismiss() }; action() } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(FrogStyle.muted)
                Text(L10n.text(title))
                Spacer()
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                if let key { Text(key).font(FrogType.caption).foregroundStyle(FrogStyle.muted) }
            }.padding(.horizontal, 8).frame(height: FrogStyle.controlHeight).contentShape(Rectangle())
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
