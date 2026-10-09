import SwiftUI

struct StayAwakeSettingsView: View {
    @ObservedObject var power: StayAwakeController

    var body: some View {
        SettingsSection(title: "Stay awake") {
            CompactRow(title: "Lid-closed access", detail: "Keeps background work running while your Mac is locked or its lid is closed. Off until you enable it in the menu bar.") {
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
