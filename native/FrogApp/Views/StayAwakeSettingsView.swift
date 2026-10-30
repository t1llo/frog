import SwiftUI

struct StayAwakeView: View {
    @ObservedObject var power: StayAwakeController
    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Stay awake")
            FrogSection("Session", footer: "The screen can lock while background work continues.") {
                FrogRow("Keep this Mac awake", caption: "Stops on quit, or below 20% battery when unplugged.") {
                    Toggle("Keep this Mac awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!power.canSwitch)
                }
                FrogRow("Duration") {
                    FrogDropdown(selected: power.duration, options: StayAwakeController.DurationChoice.allCases,
                                 title: { $0.title }) { power.duration = $0 }.disabled(power.isEnabled || power.isBusy)
                }
                if let deadline = power.deadline, power.isEnabled {
                    FrogRowNote(text: "Until \(deadline.formatted(date: .omitted, time: .shortened))")
                }
                if let error = power.error { InlineIssue(message: error).padding(.vertical, 6) }
                else if let notice = power.notice { FrogRowNote(text: notice) }
            }
            StayAwakeMenuBarSettings()
            StayAwakeSettingsView(power: power)
        }.task { await power.refresh() }
    }
}

struct StayAwakeSettingsView: View {
    @ObservedObject var power: StayAwakeController

    var body: some View {
        FrogSection("Access", footer: "Setup and Reset run in Terminal, which asks for your password.") {
            FrogRow("Lid-closed access", caption: "Lets Frog change the sleep setting.") {
                Label(power.accessState.title, systemImage: power.accessState == .ready ? "checkmark.circle.fill" : "info.circle")
                    .font(FrogType.small).foregroundStyle(power.accessState == .ready ? FrogStyle.accent : FrogStyle.muted)
            }
            if case .unavailable(let message) = power.accessState {
                FrogRowNote(text: message, tone: FrogStyle.warning)
            }
            if let notice = power.accessNotice { FrogRowNote(text: notice) }
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup("How this works") {
                    Text("Setup adds a rule in /etc/sudoers.d/frog-awake that lets your account run pmset -a disablesleep 0 and 1 without a password. Reset restores sleep and empties that file; the main sudoers file is never edited.")
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                HStack {
                    if power.isConfiguringAccess {
                        ProgressView().controlSize(.small)
                        Text("Finish the guide in Terminal…").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        Spacer()
                        Button("Cancel") { power.cancelAccessGuide() }
                    } else {
                        if power.accessState != .ready { Button("Set up access…") { power.configureAccess() }.buttonStyle(.frog(.primary)) }
                        Button("Check access") { Task { await power.refreshAccess(force: true) } }
                        Spacer()
                        Button("Reset access…") { power.configureAccess(.reset) }.buttonStyle(.frog(.ghost)).disabled(power.isBusy)
                    }
                }
            }.padding(.vertical, 10)
        }.task { await power.refreshAccess() }
    }
}
