import Foundation
import Combine

/// Tracks a user-started session, not a preference that automatically enables on launch.
@MainActor
final class StayAwakeController: ObservableObject {
    enum AccessState: Equatable {
        case checking, ready, needsSetup, unavailable(String)
        var title: String {
            switch self {
            case .checking: "Checking access…"
            case .ready: "Ready to use"
            case .needsSetup: "Setup needed"
            case .unavailable: "Could not verify access"
            }
        }
    }
    enum DurationChoice: TimeInterval, CaseIterable, Identifiable {
        case halfHour = 1800, hour = 3600, fourHours = 14400, untilQuit = 0
        var id: Self { self }
        var title: String {
            switch self { case .halfHour: "30 minutes"; case .hour: "1 hour"; case .fourHours: "4 hours"; case .untilQuit: "Until quit" }
        }
    }
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var hasReadState = false
    @Published private(set) var accessState: AccessState = .checking
    @Published private(set) var isConfiguringAccess = false
    @Published private(set) var accessNotice: String?
    @Published private(set) var error: String?
    @Published private(set) var deadline: Date?
    @Published private(set) var notice: String?
    @Published var duration: DurationChoice = .fourHours
    private(set) var ownsSession = false
    private let system: any StayAwakeSystem
    private let sessionFile: URL
    private let now: () -> Date
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var revision = 0
    private var started = false
    private var quitting = false
    private var featureEnabled = true
    private var accessCheck: Task<Void, Never>?
    private var accessRevision = 0
    private var permissionError = false
    private var accessGuide: Task<Void, Never>?
    private let openGuide: (StayAwakeSetup.Mode) async throws -> StayAwakeSetup.Session
    private struct Session: Codable { var deadline: Date? }

    init(system: any StayAwakeSystem = NativeStayAwakeSystem(), directory: URL? = nil, now: @escaping () -> Date = Date.init,
         openGuide: @escaping (StayAwakeSetup.Mode) async throws -> StayAwakeSetup.Session = { try await StayAwakeSetup.open($0) }) {
        self.system = system; self.now = now; self.openGuide = openGuide
        let directory = directory ?? ProcessInfo.processInfo.environment["FROG_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Frog")
        sessionFile = directory.appendingPathComponent("stay-awake-session.json")
    }

    var needsQuitCleanup: Bool { ownsSession || isBusy }
    var needsSetup: Bool { accessState == .needsSetup }

    func configureFeature(enabled: Bool) {
        featureEnabled = enabled
        if !enabled, !ownsSession, !isBusy { monitor?.cancel(); monitor = nil }
        else if enabled, started { beginMonitoring() }
        if enabled, started, !hasReadState { operation = Task { await refresh(); await refreshAccess() } }
    }

    func refreshAccess(force: Bool = false) async {
        guard featureEnabled || ownsSession else { return }
        if force { accessRevision += 1; accessCheck?.cancel(); accessCheck = nil }
        if let accessCheck { await accessCheck.value; return }
        let token = accessRevision
        let check = Task {
            do {
                let allowed = try await system.hasAccess()
                guard !Task.isCancelled, token == accessRevision else { return }
                accessState = allowed ? .ready : .needsSetup
                if allowed, permissionError { error = nil; permissionError = false }
            } catch {
                if !Task.isCancelled, token == accessRevision { accessState = .unavailable(error.localizedDescription) }
            }
        }
        accessCheck = check
        await check.value
        if token == accessRevision { accessCheck = nil }
    }

    func configureAccess(_ mode: StayAwakeSetup.Mode = .setup) {
        guard !isConfiguringAccess, !quitting else { return }
        isConfiguringAccess = true; accessNotice = nil
        accessGuide = Task {
            defer { isConfiguringAccess = false }
            do {
                if mode == .reset {
                    await operation?.value
                    // Restore sleep while the existing permission still exists.
                    guard await change(false) else {
                        accessNotice = error ?? "Restore sleep before resetting access."
                        return
                    }
                }
                let session = try await openGuide(mode)
                let result = try await session.waitForResult()
                session.remove()
                await refreshAccess(force: true); await refresh()
                switch result {
                case .success:
                    if mode == .reset {
                        accessNotice = accessState == .ready ? "Frog's access file is empty. Another system rule still allows stay awake." : "Access reset. Set up again to use Stay awake."
                    } else {
                        accessNotice = accessState == .ready ? "Access verified. You can now use Stay awake from the menu bar." : "Setup finished, but both power commands are not yet allowed. Review the setup and try again."
                    }
                case .cancelled: accessNotice = "Access guide cancelled."
                case .failed: accessNotice = "Setup did not finish. Review the Terminal window and try again."
                }
            } catch is CancellationError { }
            catch { accessNotice = error.localizedDescription }
        }
    }

    func waitForAccessGuide() async { await accessGuide?.value }

    func start() {
        guard !started else { return }; started = true
        operation = Task {
            do {
                if FileManager.default.fileExists(atPath: sessionFile.path) {
                    let previous = try JSONDecoder().decode(Session.self, from: Data(contentsOf: sessionFile))
                    ownsSession = true; deadline = previous.deadline
                    // A previous process did not finish cleanup. Never resume an
                    // enabled session automatically after a crash or restart.
                    _ = await change(false)
                } else { await refresh() }
            } catch { self.error = error.localizedDescription }
            await refreshAccess()
            beginMonitoring()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy, !quitting, hasReadState, !enabled || (featureEnabled && !isConfiguringAccess) else { return }
        isBusy = true; revision += 1
        operation = Task { _ = await change(enabled) }
    }

    func waitForOperation() async { await operation?.value }

    func refresh() async {
        guard !isBusy, !quitting, featureEnabled || ownsSession else { return }
        let token = revision
        do {
            let enabled: Bool
            do { enabled = try await system.sleepDisabled() }
            catch {
                if token == revision, !isBusy, !quitting { hasReadState = false }
                throw error
            }
            guard token == revision, !isBusy, !quitting else { return }
            isEnabled = enabled; hasReadState = true
            if !enabled, ownsSession { try clearSession() }
            guard enabled, ownsSession else { return }
            if let deadline, now() >= deadline {
                setEnabled(false); await waitForOperation()
                if !isEnabled { notice = "Timer finished · Sleep restored" }
                return
            }
            let battery = try await system.battery()
            guard token == revision, !isBusy, !quitting else { return }
            if battery.onBattery, let percent = battery.percent, percent < 20 {
                setEnabled(false); await waitForOperation()
                if !isEnabled { notice = "Low battery · Sleep restored" }
            }
        } catch { if token == revision, !quitting { self.error = error.localizedDescription } }
    }

    func prepareToQuit() async -> Bool {
        quitting = true; monitor?.cancel(); monitor = nil
        await operation?.value
        guard ownsSession else { return true }
        let restored = await change(false)
        if !restored { quitting = false; beginMonitoring() }
        return restored
    }

    private func change(_ enabled: Bool) async -> Bool {
        isBusy = true; revision += 1; error = nil; permissionError = false; notice = nil
        defer { isBusy = false }
        do {
            let current = try await system.sleepDisabled()
            isEnabled = current; hasReadState = true
            if current == enabled {
                if !enabled { try clearSession() }
                return true
            }
            if enabled {
                guard try await system.hasAccess() else { throw StayAwakeError.permission }
                let battery = try await system.battery()
                if battery.onBattery, let percent = battery.percent, percent < 20 { throw StayAwakeError.lowBattery }
                let end = duration == .untilQuit ? nil : now().addingTimeInterval(duration.rawValue)
                try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Save intent first so a crash between the command and readback
                // cannot leave an untracked system-wide setting behind.
                try JSONEncoder().encode(Session(deadline: end)).write(to: sessionFile, options: .atomic)
                ownsSession = true; deadline = end
            }
            try await system.setSleepDisabled(enabled)
            let actual = try await system.sleepDisabled()
            isEnabled = actual
            guard actual == enabled else { throw StayAwakeError.notApplied }
            if enabled { accessState = .ready }
            if !enabled { try clearSession() }
            return true
        } catch {
            self.error = error.localizedDescription
            if case StayAwakeError.permission = error {
                accessRevision += 1; accessCheck?.cancel(); accessCheck = nil
                permissionError = true
                accessState = .needsSetup
            }
            if let actual = try? await system.sleepDisabled() {
                isEnabled = actual; hasReadState = true
                if !actual { try? clearSession() }
            } else { hasReadState = false }
            return false
        }
    }

    private func clearSession() throws {
        if FileManager.default.fileExists(atPath: sessionFile.path) { try FileManager.default.removeItem(at: sessionFile) }
        ownsSession = false; deadline = nil
    }

    private func beginMonitoring() {
        guard !quitting, monitor == nil, featureEnabled || ownsSession else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                if self.ownsSession || !self.hasReadState { await self.refresh() }
            }
        }
    }

    isolated deinit { monitor?.cancel(); operation?.cancel(); accessCheck?.cancel(); accessGuide?.cancel() }
}
