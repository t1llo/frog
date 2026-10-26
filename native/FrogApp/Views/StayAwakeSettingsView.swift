import SwiftUI

struct StayAwakeView: View {
    @ObservedObject var power: StayAwakeController
    var body: some View {
        PageScroll {
            PageHeader(title: "Stay awake")
            SettingsSection(title: "Session") {
                CompactRow(title: "Keep this Mac awake", detail: "Stops on quit, or below 20% battery when unplugged.") {
                    Toggle("Keep this Mac awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!power.canSwitch)
                }
                Divider()
                CompactRow(title: "Duration") {
                    CompactMenu(value: power.duration.title) {
                        ForEach(StayAwakeController.DurationChoice.allCases) { duration in
                            Button { power.duration = duration } label: {
                                HStack {
                                    Text(L10n.text(duration.title))
                                    Spacer()
                                    if power.duration == duration {
                                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(FrogStyle.accent)
                                    }
                                }
                            }.accessibilityAddTraits(power.duration == duration ? .isSelected : [])
                        }
                    }.disabled(power.isEnabled || power.isBusy)
                }
                if let deadline = power.deadline, power.isEnabled {
                    Text("Until \(deadline.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(FrogStyle.muted)
                }
                if let error = power.error { InlineIssue(message: error) }
                else if let notice = power.notice { Text(notice).font(.caption).foregroundStyle(FrogStyle.muted) }
            }
            Text("The screen can lock while background work continues.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            StayAwakeMenuBarSettings()
            StayAwakeSettingsView(power: power)
        }.task { await power.refresh() }
    }
}

struct StayAwakeSettingsView: View {
    @ObservedObject var power: StayAwakeController

    var body: some View {
        SettingsSection(title: "Access") {
            CompactRow(title: "Lid-closed access", detail: "Lets Frog change the sleep setting.") {
                Label(power.accessState.title, systemImage: power.accessState == .ready ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 11)).foregroundStyle(power.accessState == .ready ? FrogStyle.accent : FrogStyle.muted)
            }
            if case .unavailable(let message) = power.accessState {
                Text(message).font(.system(size: 11)).foregroundStyle(FrogStyle.warning)
            } else if power.accessState == .ready {
                Text("Both power commands are allowed without a password. Stay awake is ready to use.")
                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            }
            if let notice = power.accessNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Reset restores sleep and removes Frog's permission to change it. Terminal shows each command first; your administrator password stays there.")
                .font(FrogType.caption).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("How this works") {
                Text("Setup adds a rule in /etc/sudoers.d/frog-awake that lets your account run pmset -a disablesleep 0 and 1 without a password. Reset restores sleep and empties that file; the main sudoers file is never edited.")
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }.font(FrogType.caption).foregroundStyle(FrogStyle.muted)
            HStack {
                if power.isConfiguringAccess {
                    ProgressView().controlSize(.small)
                    Text("Finish the guide in Terminal…").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    Spacer()
                    Button("Cancel") { power.cancelAccessGuide() }
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
