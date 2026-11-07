import SwiftUI
import FrogCore

/// Stay awake's page: where the Mac stands with the switch that changes it, then the session and the menu-bar cup.
struct StayAwakePage: View {
    @ObservedObject var power: StayAwakeController
    @ObservedObject var plugin: StayAwakePlugin
    private var settings: StayAwakeSettings { plugin.settings }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Stay awake", subtitle: "Keep your Mac from sleeping, for a while or until you stop it.")
            // Where the Mac stands, at a glance, with the one switch that changes it.
            StayAwakeStatusCard(power: power, keepScreenOn: settings.keepScreenOn)
            FrogSection("Session") {
                // Duration sets up the next session as well as the running one, so it stays fully available.
                FrogRow("Duration") {
                    FrogDropdown(selected: settings.duration, options: StayAwakeController.DurationChoice.allCases, title: { $0.title }) { choice in
                        change(reveal: true) { settings in settings.duration = choice }
                    }
                }
                if settings.duration == .untilTime {
                    FrogRow("Until") {
                        FrogDropdown(selected: settings.until, options: Self.times(including: settings.until), searchPrompt: "Time",
                                     title: Self.title(of:)) { time in change { $0.until = time } }
                    }
                }
                // Only a running session keeps a screen lit, so while none runs the switch is disabled, drawn as
                // macOS draws a switch that cannot be changed, and its caption says what it waits for.
                FrogRow("Keep the screen on", caption: !power.isEnabled ? "Available while this Mac is kept awake."
                        : settings.keepScreenOn ? "The display stays lit as well." : "The display can sleep while apps keep running.") {
                    Toggle("Keep the screen on", isOn: Binding(get: { settings.keepScreenOn }, set: { on in change { $0.keepScreenOn = on } }))
                        .labelsHidden().toggleStyle(.frogSwitch).controlSize(.small).disabled(!power.isEnabled)
                }
                // Keeping awake with the lid closed is a way of keeping awake too, so it sits with the session.
                LidClosedRows(power: power, lid: power.lid, on: settings.lidClosed) { on in change(reveal: true) { $0.lidClosed = on } }
            }
            FrogSection("Menu bar") {
                FrogRow("Show in the menu bar", caption: "While this Mac is kept awake.") {
                    Toggle("Show in the menu bar", isOn: Binding(get: { settings.menuBarItem }, set: { on in change(reveal: true) { $0.menuBarItem = on } }))
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

/// The top of the page: the feature's tile (a full cup while a session runs, as in Frog's menu), the state in the page's large type ("Awake
/// until 17:30", "Sleeps as usual"), what it means under it, and the switch that starts or ends the session.
private struct StayAwakeStatusCard: View {
    @ObservedObject var power: StayAwakeController
    let keepScreenOn: Bool

    var body: some View {
        let on = power.isEnabled
        FrogSection {
            HStack(spacing: FrogStyle.space12) {
                PluginIconTile(symbol: on ? "cup.and.saucer.fill" : "cup.and.saucer", tint: StayAwakePlugin.info.tint.color,
                               size: .header)
                VStack(alignment: .leading, spacing: FrogStyle.space2) {
                    Text(L10n.text(title)).font(FrogType.title).foregroundStyle(FrogStyle.ink).lineLimit(1)
                    // The time left counts down by the minute while a session with an end runs.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(caption(at: FrogClock.now(or: context.date))).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: FrogStyle.space8)
                Toggle("Keep this Mac awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                    .labelsHidden().toggleStyle(.frogSwitch)
            }
            .padding(.vertical, FrogStyle.space12)
            .accessibilityElement(children: .contain)
        }
    }

    private var title: String {
        guard power.isEnabled else { return "Sleeps as usual" }
        guard let deadline = power.deadline else { return "Awake until turned off" }
        return "Awake until \(deadline.formatted(date: .omitted, time: .shortened))"
    }

    private func caption(at now: Date) -> String {
        guard power.isEnabled else { return L10n.text("Your Mac sleeps when idle. Turn this on to keep it awake.") }
        let screen = L10n.text(keepScreenOn ? "The screen stays on." : "The screen can sleep.")
        guard let deadline = power.deadline else { return screen }
        let left = Duration.seconds(max(60, deadline.timeIntervalSince(now)))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, fractionalPart: .hide))
        return "\(left) \(L10n.text("left")). \(screen)"
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
