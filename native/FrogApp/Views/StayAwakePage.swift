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
            FrogPageHeader(title: "Stay awake", subtitle: power.statusText)
            FrogSection {
                FrogRow("Keep this Mac awake") {
                    Toggle("Keep this Mac awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                        .labelsHidden().toggleStyle(.switch)
                }
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
                FrogRow("Keep the screen on") {
                    Toggle("Keep the screen on", isOn: Binding(get: { settings.keepScreenOn }, set: { on in change { $0.keepScreenOn = on } }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            LidClosedSection(power: power, lid: power.lid, on: settings.lidClosed) { on in change(reveal: true) { $0.lidClosed = on } }
            FrogSection("Menu bar") {
                FrogRow("Show a cup while on") {
                    Toggle("Show a cup while on", isOn: Binding(get: { settings.menuBarItem }, set: { on in change(reveal: true) { $0.menuBarItem = on } }))
                        .labelsHidden().toggleStyle(.switch)
                }
                if settings.menuBarItem {
                    // A session with two hours and twenty minutes of four left.
                    let deadline = Date().addingTimeInterval(140 * 60 + 30)
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

/// The lid-closed mode: a system setting that needs a one-time setup in Terminal, kept apart from the session,
/// which needs none.
private struct LidClosedSection: View {
    @ObservedObject var power: StayAwakeController
    @ObservedObject var lid: LidClosedSleep
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        FrogSection("Lid closed") {
            FrogRow("Stay awake with the lid closed", caption: on ? nil : "Needs a one-time setup in Terminal.") {
                Toggle("Stay awake with the lid closed", isOn: Binding(get: { on }, set: set))
                    .labelsHidden().toggleStyle(.switch)
            }
            if on {
                FrogRow("Access") {
                    if lid.isConfiguringAccess {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Finish in Terminal…").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                            Button("Cancel") { lid.cancelAccessGuide() }.buttonStyle(.frog(.ghost))
                        }
                    } else if lid.accessState == .ready {
                        HStack(spacing: 8) {
                            Label("Ready", systemImage: "checkmark.circle.fill").font(FrogType.small).foregroundStyle(FrogStyle.accent)
                            Button("Reset…") { lid.configureAccess(.reset) }.buttonStyle(.frog(.ghost)).disabled(lid.isBusy)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button("Check") { Task { await lid.refreshAccess(force: true) } }.buttonStyle(.frog(.ghost))
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

/// Stay awake in the Frog popup: the switch, and the duration while off; while on, when the session ends.
struct StayAwakePopupRow: View {
    @ObservedObject var power: StayAwakeController
    let choose: (StayAwakeController.DurationChoice) -> Void
    @State private var choosingDuration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("Stay awake", systemImage: power.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(FrogType.bodyMedium).fixedSize()
                Spacer(minLength: 0)
                if power.isBusy { ProgressView().controlSize(.mini) }
                if power.isEnabled {
                    Text(power.deadline.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Until turned off")
                        .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                } else {
                    Button { choosingDuration.toggle() } label: {
                        CompactDropdownLabel(value: L10n.text(power.duration.title), width: 112, height: FrogStyle.compactHeight)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Stay-awake duration").accessibilityValue(power.duration.title)
                }
                Toggle("Stay awake", isOn: Binding(get: { power.isEnabled }, set: power.setEnabled))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityHint("Keep this Mac awake")
            }.frame(height: FrogStyle.compactHeight)
            if choosingDuration && !power.isEnabled {
                VStack(spacing: 1) {
                    ForEach(StayAwakeController.DurationChoice.allCases) { duration in
                        Button { choose(duration); choosingDuration = false } label: {
                            HStack {
                                Text(L10n.text(duration == .untilTime ? "Until \(StayAwakePage.title(of: power.untilTime))" : duration.title))
                                Spacer()
                                if power.duration == duration {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(FrogStyle.accent)
                                }
                            }.font(FrogType.small).padding(.horizontal, 8).frame(height: FrogStyle.compactHeight).contentShape(Rectangle())
                        }.buttonStyle(MenuRowStyle()).accessibilityAddTraits(power.duration == duration ? .isSelected : [])
                    }
                }
            }
            if let message = power.error ?? power.notice {
                Text(String(message.prefix(300))).font(FrogType.caption)
                    .foregroundStyle(power.error == nil ? FrogStyle.muted : FrogStyle.warning).lineLimit(2)
                    .help("Open Stay awake for details.")
            }
        }.padding(8).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
            .padding(.horizontal, 2).padding(.bottom, 4)
            .task { await power.refresh() }
            .onChange(of: power.isEnabled) { _, _ in choosingDuration = false }
    }
}
