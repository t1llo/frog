import Foundation
import Combine

/// Tracks a user-started session, not a preference that automatically enables on launch.
@MainActor
final class StayAwakeController: ObservableObject {
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
    @Published private(set) var needsSetup = false
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
    private struct Session: Codable { var deadline: Date? }

    init(system: any StayAwakeSystem = NativeStayAwakeSystem(), directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.system = system; self.now = now
        let directory = directory ?? ProcessInfo.processInfo.environment["FROG_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Frog")
        sessionFile = directory.appendingPathComponent("stay-awake-session.json")
    }

    var needsQuitCleanup: Bool { ownsSession || isBusy }

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
            beginMonitoring()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy, !quitting, hasReadState else { return }
        isBusy = true; revision += 1
        operation = Task { _ = await change(enabled) }
    }

    func waitForOperation() async { await operation?.value }

    func refresh() async {
        guard !isBusy, !quitting else { return }
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
        isBusy = true; revision += 1; error = nil; notice = nil
        defer { isBusy = false }
        do {
            let current = try await system.sleepDisabled()
            isEnabled = current; hasReadState = true
            if current == enabled {
                if !enabled { try clearSession() }
                return true
            }
            if enabled {
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
            needsSetup = false
            if !enabled { try clearSession() }
            return true
        } catch {
            self.error = error.localizedDescription
            if case StayAwakeError.permission = error { needsSetup = true }
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
        guard !quitting, monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                if self.ownsSession || !self.hasReadState { await self.refresh() }
            }
        }
    }

    isolated deinit { monitor?.cancel(); operation?.cancel() }
}
