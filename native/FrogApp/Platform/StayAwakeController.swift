import Foundation
import Combine

/// How long a Stay awake session lasts.
enum StayAwakeLength: Equatable, Sendable {
    case untilOff
    case minutes(Int)
    /// The next time the clock shows this, today or tomorrow.
    case until(hour: Int, minute: Int)

    /// "60", "90m", "1h", "1h30m", "until 17:30", "17:30", "off" or "until-off".
    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["", "off", "until-off", "until off", "forever"].contains(text) { self = .untilOff; return }
        if text.hasPrefix("until") { text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        let clock = text.split(separator: ":")
        if clock.count == 2, let hour = Int(clock[0]), let minute = Int(clock[1]), (0..<24).contains(hour), (0..<60).contains(minute) {
            self = .until(hour: hour, minute: minute); return
        }
        var minutes = 0, number = ""
        for character in text {
            if character.isNumber { number.append(character); continue }
            guard let value = Int(number) else { return nil }
            switch character {
            case "h": minutes += value * 60
            case "m": minutes += value
            default: return nil
            }
            number = ""
        }
        // A bare number, or what follows "1h", is minutes.
        if let value = Int(number) { minutes += value }
        guard minutes > 0, minutes <= 7 * 24 * 60 else { return nil }
        self = .minutes(minutes)
    }

    func deadline(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .untilOff: return nil
        case .minutes(let minutes): return now.addingTimeInterval(TimeInterval(minutes * 60))
        case .until(let hour, let minute):
            return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
        }
    }
}

/// A Stay awake session: power assertions that keep the Mac, and by default its screen, awake until it is turned
/// off or its time is up. Nothing to set up. `lid` adds the separate "with the lid closed" mode, which changes a
/// system setting and needs a one-time setup.
@MainActor
final class StayAwakeController: ObservableObject {
    typealias AccessState = LidClosedSleep.AccessState
    /// The choices the page and the popup offer.
    enum DurationChoice: String, CaseIterable, Identifiable, Codable, Sendable {
        case untilOff = "until-off", hour = "1h", threeHours = "3h", untilTime = "until-time"
        var id: Self { self }
        var title: String {
            switch self { case .untilOff: "Until turned off"; case .hour: "1 hour"; case .threeHours: "3 hours"; case .untilTime: "Until a time" }
        }
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var deadline: Date?
    @Published private(set) var notice: String?
    @Published var duration: DurationChoice = .untilOff
    /// "HH:MM" for `.untilTime`.
    @Published var untilTime = "18:00"
    /// The cup has a menu-bar item of its own, so Frog's icon leaves out its small one.
    @Published var hasOwnMenuBarIcon = false
    @Published private(set) var keepScreenOn = true
    @Published private(set) var lidClosed = false
    let lid: LidClosedSleep
    private let holder: (any DisplayAwakeHolding)?
    private let now: () -> Date
    private var timer: Task<Void, Never>?
    private var lidTask: Task<Void, Never>?
    private var lidObservation: AnyCancellable?

    /// The app's controller: assertions only for the real system, so test systems never touch the display.
    init(system: any StayAwakeSystem = NativeStayAwakeSystem(), directory: URL? = nil, now: @escaping () -> Date = Date.init,
         monitorInterval: Duration = .seconds(60), display: (any DisplayAwakeHolding)? = nil, lidEnabled: Bool = false,
         openGuide: @escaping (StayAwakeSetup.Mode) async throws -> StayAwakeSetup.Session = { try await StayAwakeSetup.open($0) }) {
        self.now = now
        holder = display ?? (system is NativeStayAwakeSystem ? AwakeAssertion() : nil)
        lid = LidClosedSleep(system: system, directory: directory, monitorInterval: monitorInterval, enabled: lidEnabled, openGuide: openGuide)
        lidClosed = lidEnabled
        // The popup and the page show the lid's state through this object.
        lidObservation = lid.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// What `duration` and `untilTime` choose.
    var chosenLength: StayAwakeLength {
        switch duration {
        case .untilOff: .untilOff
        case .hour: .minutes(60)
        case .threeHours: .minutes(180)
        case .untilTime: StayAwakeLength("until \(untilTime)") ?? .untilOff
        }
    }

    /// From settings: whether the screen stays on too, and whether a session also keeps the Mac awake with the lid closed.
    func configure(keepScreenOn: Bool, lidClosed: Bool) {
        if self.keepScreenOn != keepScreenOn { self.keepScreenOn = keepScreenOn; if isEnabled { holder?.hold(true, screen: keepScreenOn) } }
        guard self.lidClosed != lidClosed else { return }
        self.lidClosed = lidClosed
        lid.configureFeature(enabled: lidClosed)
        if isEnabled { syncLid() }
    }

    func turnOn(_ length: StayAwakeLength? = nil) {
        let length = length ?? chosenLength
        let start = now()
        notice = nil
        startedAt = start
        deadline = length.deadline(from: start)
        isEnabled = true
        holder?.hold(true, screen: keepScreenOn)
        scheduleEnd()
        syncLid()
    }

    func turnOff() {
        timer?.cancel(); timer = nil
        let wasOn = isEnabled
        isEnabled = false; startedAt = nil; deadline = nil
        holder?.hold(false, screen: keepScreenOn)
        if wasOn || lid.ownsSession { syncLid() }
    }

    func toggle() { isEnabled ? turnOff() : turnOn() }

    /// Ends a session whose time is up. The timer calls it; so do refreshes, in case the timer ran late.
    func expireIfDue() {
        guard isEnabled, let deadline, deadline <= now() else { return }
        turnOff()
    }

    /// Waits for the lid-closed setting to follow the session.
    func waitForLid() async {
        await lidTask?.value
        await lid.waitForOperation()
    }

    /// "On until 17:30", "On until turned off", "Off".
    var statusText: String {
        guard isEnabled else { return "Off" }
        if let deadline { return "On until \(deadline.formatted(date: .omitted, time: .shortened))" }
        return "On until turned off"
    }

    private func scheduleEnd() {
        timer?.cancel(); timer = nil
        guard let deadline else { return }
        let wait = max(0, deadline.timeIntervalSince(now()))
        // ContinuousClock keeps counting while the Mac sleeps, so a session never outlives its time.
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self else { return }
            self.timer = nil
            if self.isEnabled, self.deadline == deadline { self.turnOff() }
        }
    }

    /// The lid-closed setting is on exactly while a session runs in lid-closed mode.
    private func syncLid() {
        let wanted = isEnabled && lidClosed
        let previous = lidTask
        lidTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.lid.waitForOperation()
            if wanted {
                if !self.lid.hasReadState { await self.lid.refresh() }
                await self.lid.refreshAccessUnlessReady()
                guard self.isEnabled, self.lidClosed else { return }
                if self.lid.accessState != .ready { self.notice = "Lid closed needs setup"; return }
                if !self.lid.isEnabled { self.lid.setEnabled(true); await self.lid.waitForOperation() }
            } else if self.lid.ownsSession {
                self.lid.setEnabled(false); await self.lid.waitForOperation()
            }
        }
    }

    // MARK: The app delegate and the popup

    var error: String? { lid.error }
    var isBusy: Bool { lid.isBusy }
    /// The session is Frog's own, so its state is always known.
    var hasReadState: Bool { true }
    var ownsSession: Bool { isEnabled }
    var canSwitch: Bool { !lid.isBusy }
    var accessState: AccessState { lidClosed ? lid.accessState : .checking }
    var isConfiguringAccess: Bool { lid.isConfiguringAccess }
    var needsQuitCleanup: Bool { lid.needsQuitCleanup }

    func setEnabled(_ enabled: Bool) { enabled ? turnOn() : turnOff() }
    func waitForOperation() async { await waitForLid() }
    func configureAccess() { lid.configureAccess() }

    /// At launch: restores sleep when an earlier run of Frog left the lid-closed setting on.
    func start() { lid.start() }

    func refresh() async {
        expireIfDue()
        if lidClosed || lid.ownsSession { await lid.refresh() }
    }

    func refreshAccessUnlessReady() async {
        if lidClosed { await lid.refreshAccessUnlessReady() }
    }

    func prepareToQuit() async -> Bool {
        timer?.cancel(); timer = nil
        holder?.hold(false, screen: keepScreenOn)
        await lidTask?.value
        return await lid.prepareToQuit()
    }

    isolated deinit { timer?.cancel(); lidTask?.cancel(); holder?.hold(false, screen: false) }
}
