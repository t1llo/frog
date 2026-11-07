import SwiftUI
import FrogCore

/// Stay awake's page: the session, the separate lid-closed mode, and the menu-bar cup.
struct StayAwakePage: View {
    @ObservedObject var power: StayAwakeController
    @ObservedObject var plugin: StayAwakePlugin
    private var settings: StayAwakeSettings { plugin.settings }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Stay awake", subtitle: "Keep your Mac from sleeping, for a while or until you stop it.") {
                // Where the Mac stands at a glance, on or off, beside the title.
                FrogStatePill(text: power.isEnabled ? power.statusText : "Sleeps as usual", on: power.isEnabled)
            }
            // One card, so no heading: the session, the lid and the menu-bar icon. The first row says where the
            // session stands ("On until 17:30", or that the Mac sleeps as usual).
            FrogSection {
                FrogRow("Keep this Mac awake", caption: power.isEnabled ? power.statusText : "Off. Your Mac sleeps as usual.") {
                    Toggle("Keep this Mac awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                        .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                }
                // While off, these set up the next session: they can still be changed, but read as resting, faded
                // like a disabled control, so an "on" switch never claims the screen is kept on while nothing runs.
                FrogRow("Duration") {
                    FrogDropdown(selected: settings.duration, options: StayAwakeController.DurationChoice.allCases, title: { $0.title }) { choice in
                        change(reveal: true) { settings in settings.duration = choice }
                    }.opacity(sessionOpacity)
                }
                if settings.duration == .untilTime {
                    FrogRow("Until") {
                        FrogDropdown(selected: settings.until, options: Self.times(including: settings.until), searchPrompt: "Time",
                                     title: Self.title(of:)) { time in change { $0.until = time } }
                        .opacity(sessionOpacity)
                    }
                }
                FrogRow("Keep the screen on", caption: !power.isEnabled ? "For the next session." : settings.keepScreenOn ? "The display stays lit as well." : "The display can sleep while apps keep running.") {
                    Toggle("Keep the screen on", isOn: Binding(get: { settings.keepScreenOn }, set: { on in change { $0.keepScreenOn = on } }))
                        .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small).opacity(sessionOpacity)
                }
                LidClosedRows(power: power, lid: power.lid, on: settings.lidClosed) { on in change(reveal: true) { $0.lidClosed = on } }
                FrogRow("Menu bar icon", caption: "Shows in the menu bar while this Mac is kept awake.") {
                    Toggle("Menu bar icon", isOn: Binding(get: { settings.menuBarItem }, set: { on in change(reveal: true) { $0.menuBarItem = on } }))
                        .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                }
                if settings.menuBarItem {
                    // A session with two hours and twenty minutes of four left.
                    let deadline = FrogClock.now.addingTimeInterval(140 * 60 + 30)
                    MenuBarDesignTiles(choices: StayAwakePreferences.menuBarStyles, selected: settings.menuBarStyle,
                                       title: { ["icon": "Cup", "ring": "Ring", "time": "Time left"][$0] ?? $0 }, image: { style, _ in
                        StayAwakeIcon.image(StayAwakeIcon.Face(style: style, deadline: deadline, duration: 4 * 3600))
                    }) { style in change { $0.menuBarStyle = style } }
                        .padding(.vertical, 8)
                }
            }
        }
        .task { await power.refresh() }
    }

    /// The session's own settings rest at the disabled fade while no session runs.
    private var sessionOpacity: Double { power.isEnabled ? 1 : FrogStyle.disabledOpacity }

    private func change(reveal: Bool = false, _ edit: (inout StayAwakeSettings) -> Void) {
        withAnimation(reveal && !reduceMotion ? FrogMotion.reveal : nil) { plugin.update(edit) }
    }

    /// Every half hour, and the configured time when config.toml has one in between.
    static func times(including current: String) -> [String] {
        var times = (0..<48).map { String(format: "%02d:%02d", $0 / 2, $0 % 2 * 30) }
        if !times.contains(current) { times.append(current); times.sort() }
        return times
    }

    static func title(of time: String) -> String {
        guard case .until(let hour, let minute) = StayAwakeLength("until \(time)"),
              let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) else { return time }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The lid-closed mode: a system setting that needs a one-time setup in Terminal, which the session does not, so
/// its access rows show only while it is on.
private struct LidClosedRows: View {
    @ObservedObject var power: StayAwakeController
    @ObservedObject var lid: LidClosedSleep
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space2) {
            FrogRow("Stay awake with the lid closed", caption: on ? "Turns off sleep for the whole Mac." : "Needs a one-time setup in Terminal.") {
                Toggle("Stay awake with the lid closed", isOn: Binding(get: { on }, set: set))
                    .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
            }
            if on {
                FrogRow("Access") {
                    if lid.isConfiguringAccess {
                        HStack(spacing: 8) {
                            FrogSpinner()
                            Text("Finish in Terminal…").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                            Button("Cancel") { lid.cancelAccessGuide() }.buttonStyle(.frog())
                        }
                    } else if lid.accessState == .ready {
                        HStack(spacing: 8) {
                            Label("Ready", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.good)
                            Button("Reset…") { lid.configureAccess(.reset) }.buttonStyle(.frog()).disabled(lid.isBusy)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button("Check") { Task { await lid.refreshAccess(force: true) } }.buttonStyle(.frog())
                            Button("Set up…") { lid.configureAccess() }.buttonStyle(.frog(.primary))
                        }
                    }
                }
                if case .unavailable(let message) = lid.accessState { FrogRowNote(text: message, tone: FrogStyle.warning) }
                if let error = lid.error { FrogRowNote(text: error, tone: FrogStyle.warning) }
                else if let notice = lid.accessNotice ?? lid.notice { FrogRowNote(text: notice) }
            }
        }
        .task(id: on) { if on { await lid.refreshAccess() } }
    }
}
