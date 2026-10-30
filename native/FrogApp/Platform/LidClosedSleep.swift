import Foundation
import Combine

/// "Stay awake with the lid closed": the system-wide `pmset disablesleep` setting, changed through the two
/// passwordless commands the setup guide allows. Only this part of Stay awake needs setup; the default session
/// holds power assertions (`AwakeAssertion`) and needs none.
///
/// It reads nothing until it is turned on (`configureFeature(enabled: true)`), and its once-a-minute check runs
/// only while the setting is on. A session it started survives a crash in the setting itself, so a marker file
/// lets the next launch restore sleep.
@MainActor
final class LidClosedSleep: ObservableObject {
    enum AccessState: Equatable {
        case checking, ready, needsSetup, unavailable(String)
        var title: String {
            switch self {
            case .checking: "Checking access…"
            case .ready: "Ready"
            case .needsSetup: "Setup needed"
            case .unavailable: "Could not check access"
            }
        }
    }
    /// Whether sleep is disabled system-wide, by Frog or anything else.
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var hasReadState = false
    @Published private(set) var accessState: AccessState = .checking
    @Published private(set) var isConfiguringAccess = false
    @Published private(set) var accessNotice: String?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private(set) var ownsSession = false
    private let system: any StayAwakeSystem
    private let sessionFile: URL
    private let monitorInterval: Duration
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var revision = 0
    private var started = false
    private var quitting = false
    private(set) var featureEnabled: Bool
    private var accessCheck: Task<Void, Never>?
    private var accessRevision = 0
    private var permissionError = false
    /// The error came from reading the setting, not from a change that was asked for, so
    /// the next read that works takes it away again.
    private var readError = false
    private var accessGuide: Task<Void, Never>?
    private let openGuide: (StayAwakeSetup.Mode) async throws -> StayAwakeSetup.Session
    private struct Session: Codable {
        // The process that owns the session. Markers of earlier versions have neither.
        var pid: Int32?
        var started: Int64?
        /// Only an owner that is proven to be another process still running keeps its
        /// session. In every other case the marker is a leftover that must be cleaned up.
        var ownerRunsElsewhere: Bool {
            guard let pid, let started, pid != getpid() else { return false }
            return LidClosedSleep.processStart(pid) == started
        }
    }

    /// `enabled`: whether it reads the setting from the start. The app starts with it off, until Stay awake's
    /// lid-closed switch is on.
    init(system: any StayAwakeSystem = NativeStayAwakeSystem(), directory: URL? = nil, monitorInterval: Duration = .seconds(60),
         enabled: Bool = true,
         openGuide: @escaping (StayAwakeSetup.Mode) async throws -> StayAwakeSetup.Session = { try await StayAwakeSetup.open($0) }) {
        self.system = system; self.monitorInterval = monitorInterval; self.openGuide = openGuide; featureEnabled = enabled
        let directory = directory ?? ProcessInfo.processInfo.environment["FROG_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Frog")
        sessionFile = directory.appendingPathComponent("stay-awake-session.json")
    }

    var needsQuitCleanup: Bool { ownsSession || isBusy }
    var needsSetup: Bool { accessState == .needsSetup }
    /// An open guide keeps the setting from being turned on, never from being turned off.
    var canSwitch: Bool { !isBusy && hasReadState && (isEnabled || !isConfiguringAccess) }

    func configureFeature(enabled: Bool) {
        featureEnabled = enabled
        if !enabled, !ownsSession, !isBusy {
            monitor?.cancel(); monitor = nil
            // Nothing reads the setting while the feature is off. Do not keep showing a
            // state that is no longer checked, and drop a read that is still under way.
            revision += 1
            if isEnabled { isEnabled = false }
            if hasReadState { hasReadState = false }
        }
        if enabled, started, !hasReadState {
            // The launch cleanup may still be restoring sleep. Follow it instead of replacing
            // it: quitting and disabling the feature wait for `operation`.
            let previous = operation
            operation = Task { await previous?.value; await refresh(); await refreshAccess() }
        }
    }

    /// For checks nobody asked for: opening the popup and returning to Frog. Each check runs
    /// `sudo`, and access that is ready is checked again before switching on and on the
    /// Stay awake page, so only access still to be set up is looked at here.
    func refreshAccessUnlessReady() async {
        guard accessState != .ready else { return }
        await refreshAccess()
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
                var endedSession = false
                if mode == .reset {
                    await operation?.value
                    guard !quitting else { return }
                    // Restore sleep while the existing permission still exists. The restore
                    // runs as `operation`, so quitting and disabling the feature wait for it.
                    endedSession = isEnabled || ownsSession
                    isBusy = true; revision += 1
                    let restore = Task { await change(false) }
                    operation = Task { _ = await restore.value }
                    guard await restore.value else {
                        accessNotice = error ?? "Restore sleep before resetting access."
                        return
                    }
                }
                // Quit may have arrived meanwhile. Do not open Terminal as Frog exits.
                guard !quitting else { return }
                // Nor after Cancel: nothing would wait for that window.
                var result: StayAwakeSetup.Result? = .cancelled
                if !Task.isCancelled {
                    let session = try await openGuide(mode)
                    // Only Cancel ends the wait without a result.
                    result = try? await session.waitForResult()
                    session.remove()
                    // Also then: the guide may have changed the rule before the wait ended.
                    await refreshAccess(force: true); await refresh()
                }
                switch result {
                case .success:
                    if mode == .reset {
                        accessNotice = accessState == .ready ? "Frog's access file is empty. Another system rule still allows stay awake." : "Access reset."
                    } else {
                        accessNotice = accessState == .ready ? "Access verified." : "Setup finished, but both power commands are not yet allowed. Review the setup and try again."
                    }
                // Answering no in the reset guide keeps the permission, not the session.
                case .cancelled: accessNotice = endedSession ? "Sleep restored. Access guide cancelled." : "Access guide cancelled."
                // A guide that ends early may have saved the rule already. A reset that fails
                // has removed nothing, so there access that is still ready is the failure.
                // Closing the window or Control-C also ends a reset guide this way.
                case .failed:
                    accessNotice = mode == .setup && accessState == .ready
                        ? "Setup did not finish, but both power commands are allowed."
                        : (endedSession ? "Sleep restored. " : "") + "Setup did not finish. Review the Terminal window and try again."
                case nil: accessNotice = (endedSession ? "Sleep restored. " : "") + "Stopped waiting for the guide. Close its Terminal window if it is still open."
                }
            } catch is CancellationError { }
            catch { accessNotice = error.localizedDescription }
        }
    }

    /// For a guide that never reports back, for example because Terminal could not run it.
    func cancelAccessGuide() { accessGuide?.cancel() }

    func waitForAccessGuide() async { await accessGuide?.value }

    /// At launch: restores sleep after a session that a previous run of Frog did not end. Without a marker it
    /// reads nothing unless the feature is on.
    func start() {
        guard !started else { return }; started = true
        let marker = FileManager.default.fileExists(atPath: sessionFile.path)
        guard marker || featureEnabled else { return }
        operation = Task {
            if marker {
                // A marker that cannot be read still says that Frog started a session.
                let previous = try? JSONDecoder().decode(Session.self, from: Data(contentsOf: sessionFile))
                if previous?.ownerRunsElsewhere == true {
                    // Another copy of Frog is running and owns this session, for example
                    // an installed and a development build. Show it, do not end it.
                    await refresh()
                } else {
                    ownsSession = true
                    // A previous process did not finish cleanup. Never resume an
                    // enabled session automatically after a crash or restart.
                    _ = await change(false)
                }
            } else { await refresh() }
            await refreshAccess()
            updateMonitoring()
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
        defer { updateMonitoring() }
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
            guard enabled, ownsSession else { clearReadError(); return }
            let battery = try await system.battery()
            guard token == revision, !isBusy, !quitting else { return }
            if battery.onBattery, let percent = battery.percent, percent < 20 {
                setEnabled(false); await waitForOperation()
                if !isEnabled { notice = "Low battery · Sleep restored" }
            } else { clearReadError() }
        } catch { if token == revision, !quitting { self.error = error.localizedDescription; readError = true } }
    }

    /// Only after everything was read: a battery that still cannot be read keeps its message.
    private func clearReadError() {
        if readError { error = nil; readError = false }
    }

    func prepareToQuit() async -> Bool {
        quitting = true; monitor?.cancel(); monitor = nil
        await operation?.value
        guard ownsSession else { return true }
        let restored = await change(false)
        if !restored { quitting = false; updateMonitoring() }
        return restored
    }

    private func change(_ enabled: Bool) async -> Bool {
        isBusy = true; revision += 1; error = nil; permissionError = false; readError = false; notice = nil
        defer { isBusy = false; updateMonitoring() }
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
                try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Save intent first so a crash between the command and readback
                // cannot leave an untracked system-wide setting behind.
                try JSONEncoder().encode(Session(pid: getpid(), started: Self.processStart(getpid()))).write(to: sessionFile, options: .atomic)
                ownsSession = true
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

    /// When the kernel started a process, in microseconds since 1970, or nil when no such
    /// process runs. A process id alone is reused, also across restarts of the Mac; together
    /// with this time it names one run of one process.
    nonisolated static func processStart(_ pid: pid_t) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid, Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec)
    }

    private func clearSession() throws {
        if FileManager.default.fileExists(atPath: sessionFile.path) { try FileManager.default.removeItem(at: sessionFile) }
        ownsSession = false
    }

    /// The check runs only while the setting is on, Frog owns a session, or the last read failed: it notices
    /// another tool switching the setting off and an unplugged battery running low. With the setting off, nothing runs.
    private func updateMonitoring() {
        let wanted = !quitting && (featureEnabled || ownsSession) && (ownsSession || isEnabled || !hasReadState)
        if !wanted { monitor?.cancel(); monitor = nil; return }
        guard monitor == nil else { return }
        monitor = Task { [weak self, monitorInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: monitorInterval) } catch { return }
                guard let self else { return }
                if !(self.ownsSession || self.isEnabled || !self.hasReadState) { self.monitor = nil; return }
                await self.refresh()
            }
        }
    }

    isolated deinit { monitor?.cancel(); operation?.cancel(); accessCheck?.cancel(); accessGuide?.cancel() }
}
