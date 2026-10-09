import AppKit
import SwiftUI

struct FrogMenuLabel: View {
    @ObservedObject var power: StayAwakeController
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: FrogMenuIcon.image).renderingMode(.template)
            if power.isEnabled { Image(systemName: "cup.and.saucer.fill").font(.system(size: 11)) }
        }.accessibilityLabel(power.isEnabled ? "Frog, stay awake on" : "Frog")
    }
}

struct FrogStatusMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var power: StayAwakeController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(nsImage: FrogMenuIcon.image).renderingMode(.template)
                Text("Frog").font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle().fill(model.dictation.phase == .recording ? Color.red : FrogStyle.accent).frame(width: 5, height: 5)
                Text(model.dictation.active ? model.dictation.phase.rawValue.capitalized : model.isProcessing ? "Working…" : "Ready")
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            }.padding(.horizontal, 8).padding(.vertical, 9)
            Divider().padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 7) {
                Toggle(isOn: Binding(get: { power.isEnabled }, set: power.setEnabled)) {
                    Label("Stay awake", systemImage: power.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch).disabled(power.isBusy || !power.hasReadState || power.isConfiguringAccess)
                    .accessibilityHint("Keep this Mac awake, including with the lid closed")
                HStack(spacing: 4) {
                    if power.isBusy { ProgressView().controlSize(.mini) }
                    if !power.hasReadState { Text("Checking sleep setting…") }
                    else if let deadline = power.deadline, power.isEnabled {
                        Text("Until \(deadline.formatted(date: .omitted, time: .shortened))")
                    } else { Text(power.isEnabled ? (power.ownsSession ? "Until Frog quits" : "Enabled outside Frog") : "Off · Lid sleep allowed") }
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(StayAwakeController.DurationChoice.allCases) { duration in
                            Button { power.duration = duration } label: {
                                if power.duration == duration { Label(duration.title, systemImage: "checkmark") }
                                else { Text(duration.title) }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) { Text(power.duration.title); Image(systemName: "chevron.down").font(.system(size: 8)) }
                            .foregroundStyle(FrogStyle.muted)
                    }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(power.isEnabled || power.isBusy)
                        .accessibilityLabel("Stay-awake duration")
                }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                if let error = power.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if let notice = power.notice {
                    Text(notice).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                }
                HStack {
                    Text("Lid closed included").foregroundStyle(FrogStyle.muted)
                    Spacer()
                    if power.isConfiguringAccess { Text("Finish in Terminal…").foregroundStyle(FrogStyle.muted) }
                    else if power.accessState == .checking { Text("Checking access…").foregroundStyle(FrogStyle.muted) }
                    else if power.accessState != .ready {
                        Button("Set up access…") { power.configureAccess(); dismiss() }.buttonStyle(.plain)
                    }
                }.font(.system(size: 10))
            }.padding(10).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6)).padding(6)

            if model.dictation.active {
                if model.dictation.phase == .recording {
                    action("Stop recording", symbol: "stop.fill") { model.dictation.stop(models: model.localModels) }
                }
                action("Cancel recording", symbol: "xmark") { model.dictation.interrupt() }
            }
            if model.isProcessing { action("Cancel processing", symbol: "xmark") { model.cancelProcessing() } }
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    IconAction(title: "Dismiss error", symbol: "xmark", action: model.dismissError)
                }.padding(8)
            }
            Divider().padding(.horizontal, 8)
            action(model.setupPresented ? "Set up Frog…" : "Open Frog", symbol: "arrow.up.forward.app", key: "⌘,") {
                dismiss(); model.showSettings()
            }.keyboardShortcut(",")
            if model.configuration.preferences.workflowSettings.clipboardHistoryEnabled == true {
                action("Clipboard history", symbol: "clipboard") { dismiss(); model.showClipboardHistory() }
            }
            Divider().padding(.horizontal, 8)
            HStack {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                Spacer()
                Button("Quit Frog") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted).padding(.horizontal, 9).padding(.vertical, 8)
        }.padding(5).frame(width: 292).fixedSize(horizontal: false, vertical: true)
            .font(.system(size: 12)).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
            .background(FrogStyle.panelSurface)
            .task { model.refreshSystemStatus(); await power.refresh(); await power.refreshAccess() }
    }

    private func action(_ title: String, symbol: String, key: String? = nil, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(FrogStyle.muted)
                Text(L10n.text(title))
                Spacer()
                if let key { Text(key).font(.system(size: 10)).foregroundStyle(FrogStyle.muted) }
            }.padding(.horizontal, 9).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(hovered || configuration.isPressed ? FrogStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}
