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
                CompactRow(title: "Duration") {
                    CompactMenu(value: power.duration.title) {
                        ForEach(StayAwakeController.DurationChoice.allCases) { duration in
                            Button(L10n.text(duration.title)) { power.duration = duration }
                                .compactChoice(selected: power.duration == duration)
                        }
                    }.disabled(power.isEnabled || power.isBusy)
                }
                if let deadline = power.deadline, power.isEnabled {
                    Text("Until \(deadline.formatted(date: .omitted, time: .shortened))").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                }
                if let error = power.error { InlineIssue(message: error) }
                else if let notice = power.notice { Text(notice).font(FrogType.caption).foregroundStyle(FrogStyle.muted) }
            }
            Text("The screen can lock while background work continues.")
                .font(FrogType.small).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
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
                    .font(FrogType.small).foregroundStyle(power.accessState == .ready ? FrogStyle.accent : FrogStyle.muted)
            }
            if case .unavailable(let message) = power.accessState {
                Text(message).font(FrogType.small).foregroundStyle(FrogStyle.warning)
            }
            if let notice = power.accessNotice {
                Text(notice).font(FrogType.small).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            SectionCaption(text: "Setup").padding(.top, 6)
            Text("Setup and Reset run in Terminal, which asks for your password.")
                .font(FrogType.caption).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
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
        }.task { await power.refreshAccess() }
    }
}
