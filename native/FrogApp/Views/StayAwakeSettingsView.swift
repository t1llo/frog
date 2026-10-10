import SwiftUI

struct StayAwakeView: View {
    @ObservedObject var power: StayAwakeController
    var body: some View {
        PageScroll {
            PageHeader(title: "Stay awake", subtitle: "Keep background work running when you need it.")
            SettingsSection(title: "Session") {
                CompactRow(title: "Keep this Mac awake", detail: "Includes lid-closed work. Stops on quit or below 20% battery while unplugged.") {
                    Toggle("Keep this Mac awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(power.isBusy || !power.hasReadState || power.isConfiguringAccess)
                }
                Divider()
                CompactRow(title: "Duration") {
                    CompactMenu(value: power.duration.title) {
                        ForEach(StayAwakeController.DurationChoice.allCases) { duration in
                            Button(duration.title) { power.duration = duration }
                        }
                    }.disabled(power.isEnabled || power.isBusy)
                }
                if let deadline = power.deadline, power.isEnabled {
                    Text("Until \(deadline.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(FrogStyle.muted)
                }
                if let error = power.error { InlineIssue(message: error) }
                else if let notice = power.notice { Text(notice).font(.caption).foregroundStyle(FrogStyle.muted) }
            }
            Text("The display can turn off and the screen can lock while background work continues. Tasks that control on-screen apps still need an unlocked session.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            StayAwakeSettingsView(power: power)
        }.task { await power.refresh() }
    }
}

struct StayAwakeSettingsView: View {
    @ObservedObject var power: StayAwakeController

    var body: some View {
        SettingsSection(title: "Access") {
            CompactRow(title: "Lid-closed access", detail: "Configure once to allow Frog to change the sleep setting.") {
                Label(power.accessState.title, systemImage: power.accessState == .ready ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 11)).foregroundStyle(power.accessState == .ready ? FrogStyle.accent : FrogStyle.muted)
            }
            if case .unavailable(let message) = power.accessState {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
            } else if power.accessState == .ready {
                Text("Both power commands are allowed without a password. Stay awake is ready to use.")
                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            }
            if let notice = power.accessNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Reset restores sleep and empties /etc/sudoers.d/frog-awake. Setup and reset explain their commands in Terminal; your administrator password stays there.")
                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                if power.isConfiguringAccess {
                    ProgressView().controlSize(.small)
                    Text("Finish the guide in Terminal…").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                } else {
                    if power.accessState != .ready { Button("Set up access…") { power.configureAccess() } }
                    Button("Check access") { Task { await power.refreshAccess(force: true) } }
                    Spacer()
                    Button("Reset access…") { power.configureAccess(.reset) }.disabled(power.isBusy)
                }
            }
        }.task { await power.refreshAccess() }
    }
}
