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

struct FrogStatusMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var power: StayAwakeController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SystemMonitorMenuTab = .frog
    @State private var choosingDuration = false

    static let popupName = "Frog"
    private var systemMonitorEnabled: Bool { model.configuration.preferences.featureEnabled(.systemMonitor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(nsImage: FrogMenuIcon.image).renderingMode(.template)
                Text("Frog").font(FrogType.section)
                Spacer()
                if systemMonitorEnabled { SystemMonitorMenuSelector(selection: $selectedTab) }
            }.padding(.horizontal, 8).frame(height: 40)

            if systemMonitorEnabled && selectedTab == .system {
                SystemMonitorView(monitor: model.systemMonitor, presenter: .frogMenu)
            } else {
                frogControls
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
            .task { model.refreshSystemStatus(); await power.refresh(); await power.refreshAccessUnlessReady() }
            .onAppear { NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: Self.popupName) }
            .onReceive(NotificationCenter.default.publisher(for: .frogMenuPopupWillOpen)) { note in
                if note.object as? String != Self.popupName { dismiss() }
            }
            .onChange(of: systemMonitorEnabled) { _, enabled in
                if !enabled { selectedTab = .frog; model.systemMonitor.setPresented(false, for: .frogMenu) }
            }
            .onChange(of: power.isEnabled) { _, _ in choosingDuration = false }
    }

    private var frogControls: some View {
        Group {
            if model.configuration.preferences.featureEnabled(.stayAwake) { stayAwake }

            if model.dictation.active {
                if model.dictation.phase == .recording {
                    action("Stop recording", symbol: "stop.fill") { model.dictation.stop(models: model.localModels) }
                }
                action("Cancel recording", symbol: "xmark") { model.dictation.interrupt() }
            }
            if model.isProcessing { action("Cancel processing", symbol: "xmark") { model.cancelProcessing() } }
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Text(String(error.prefix(500))).font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                        .lineLimit(3).help("Full details are in Settings → Logs.")
                    Spacer(minLength: 0)
                    IconAction(title: "Dismiss error", symbol: "xmark", action: model.dismissError)
                }.padding(8)
            }
            MenuBarOrganizerNotice(organizer: model.toolkit.menuBarOrganizer)
            if model.configuration.preferences.featureEnabled(.commandBar) {
                action("Command bar", symbol: "magnifyingglass", key: HotkeyManager.display(model.configuration.preferences.toolkitSettings.effectiveCommandBarHotkey)) { dismiss(); model.showCommandBar() }
            }
            if model.configuration.preferences.workflowSettings.clipboardHistoryEnabled == true {
                action("Clipboard history", symbol: "clipboard", key: HotkeyManager.display(model.configuration.preferences.workflowSettings.effectiveClipboardHistoryHotkey)) { dismiss(); model.showClipboardHistory() }
            }
            if model.windowLayout.pickerAvailable { action("Arrange window…", symbol: "rectangle.split.2x1") { dismiss(); model.windowLayout.handle(.layoutPicker, pressed: true) } }
        }
    }

    /// One row: the duration is chosen before switching on; while on, its place shows when the session ends.
    private var stayAwake: some View {
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
                    .accessibilityHint("Keep this Mac awake, including with the lid closed")
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
    }

    private func action(_ title: String, symbol: String, key: String? = nil, perform: @escaping () -> Void) -> some View {
        MenuActionRow(title: title, symbol: symbol, key: key, action: perform)
    }
}

/// The organizer takes its arrow out of the menu bar when it cannot run, so this menu says why.
private struct MenuBarOrganizerNotice: View {
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

/// A full-width command row shared by the menu-bar popups.
struct MenuActionRow: View {
    let title: String
    let symbol: String
    var key: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(FrogStyle.muted)
                Text(L10n.text(title))
                Spacer()
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
