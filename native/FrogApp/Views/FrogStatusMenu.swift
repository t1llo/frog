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
                Text("Frog").font(.system(size: 13, weight: .semibold))
                Spacer()
                if systemMonitorEnabled { SystemMonitorMenuSelector(selection: $selectedTab) }
            }.padding(.horizontal, 8).frame(height: 42)

            if systemMonitorEnabled && selectedTab == .system {
                SystemMonitorView(monitor: model.systemMonitor)
            } else {
                frogControls
            }
            UpdateReadyRow { dismiss(); UpdateService.shared.installReadyUpdate() }
            action(model.setupPresented ? "Set up Frog…" : "Open Frog", symbol: "arrow.up.forward.app", key: "⌘,") {
                dismiss(); model.showSettings()
            }.keyboardShortcut(",")
            Divider().padding(.horizontal, 8)
            HStack {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                Spacer()
                Button("Quit Frog") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted).padding(.horizontal, 9).padding(.vertical, 8)
        }.padding(5).frame(width: 292).fixedSize(horizontal: false, vertical: true)
            .font(.system(size: 12)).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
            .frogPanel()
            .background(MenuWindowSizing())
            .task { model.refreshSystemStatus(); await power.refresh(); await power.refreshAccessUnlessReady() }
            .onAppear { NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: Self.popupName) }
            .onReceive(NotificationCenter.default.publisher(for: .frogMenuPopupWillOpen)) { note in
                if note.object as? String != Self.popupName { dismiss() }
            }
            .onChange(of: systemMonitorEnabled) { _, enabled in
                if !enabled { selectedTab = .frog; model.systemMonitor.setPresented(false) }
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
                    Text(String(error.prefix(500))).font(.system(size: 10)).foregroundStyle(FrogStyle.warning)
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
                    .font(.system(size: 12, weight: .medium)).fixedSize()
                Spacer(minLength: 0)
                if power.isBusy { ProgressView().controlSize(.mini) }
                if !power.hasReadState {
                    Text("Checking…").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                } else if power.isEnabled {
                    Text(power.deadline.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? (power.ownsSession ? "Until Frog quits" : "On outside Frog"))
                        .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                } else {
                    Button { choosingDuration.toggle() } label: {
                        CompactDropdownLabel(value: L10n.text(power.duration.title), width: 98, height: 24)
                    }.buttonStyle(.plain).disabled(power.isBusy)
                        .accessibilityLabel("Stay-awake duration").accessibilityValue(power.duration.title)
                }
                Toggle("Stay awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                    .labelsHidden().toggleStyle(.switch).disabled(!power.canSwitch)
                    .accessibilityHint("Keep this Mac awake, including with the lid closed")
            }.frame(height: 24)
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
                            }.font(.system(size: 11)).padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
                        }.buttonStyle(MenuRowStyle()).accessibilityAddTraits(power.duration == duration ? .isSelected : [])
                    }
                }
            }
            if let error = power.error {
                Text(String(error.prefix(500))).font(.system(size: 10)).foregroundStyle(FrogStyle.warning)
                    .lineLimit(3).help("Open Stay awake for details.")
            } else if let notice = power.notice {
                Text(String(notice.prefix(500))).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(3)
            }
            if power.isConfiguringAccess {
                Text("Finish in Terminal…").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            } else if power.accessState != .ready && power.accessState != .checking {
                HStack {
                    Text(power.accessState.title).foregroundStyle(FrogStyle.muted)
                    Spacer()
                    Button("Set up access…") { power.configureAccess(); dismiss() }.buttonStyle(.plain).foregroundStyle(FrogStyle.accent)
                }.font(.system(size: 10))
            }
        }.padding(.horizontal, 8).padding(.vertical, 8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6).padding(.bottom, 4)
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
                Text(notice).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
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
                if let key { Text(key).font(.system(size: 10)).foregroundStyle(FrogStyle.muted) }
            }.padding(.horizontal, 9).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}

struct MenuRowStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label.background(hovered || configuration.isPressed ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}
