import Foundation

/// A ready-to-use inventory, refreshed independently of a Command–Tab invocation.
/// Refreshes never discard the previous snapshot or publish cancelled results.
@MainActor
final class WindowSwitcherCache {
    private(set) var snapshot: WindowCatalog.Snapshot?
    private var updatedAt: ContinuousClock.Instant?
    private var refresh: Task<WindowCatalog.Snapshot, Never>?
    private var revision: UInt64 = 0
    /// Selected in the switcher, with no focus recorded since.
    private var chosen: UUID?
    /// The window `readySnapshot` last moved to the front unread, and the row it stood behind.
    private var guess: (id: UUID, behind: UUID)?

    var isRefreshing: Bool { refresh != nil }

    func update(using load: @escaping @Sendable () async -> WindowCatalog.Snapshot) async -> WindowCatalog.Snapshot? {
        if let refresh {
            let token = revision
            let result = await refresh.value
            guard token == revision, !refresh.isCancelled, !Task.isCancelled, result.isPublishable else { return snapshot }
            return result
        }
        revision &+= 1
        let token = revision
        let task = Task { await load() }
        refresh = task
        let result = await task.value
        guard token == revision else { return snapshot }
        refresh = nil
        guard !task.isCancelled, !Task.isCancelled, result.isPublishable else { return snapshot }
        snapshot = result
        chosen = nil; guess = nil
        updatedAt = result.completeness == .complete ? .now : nil
        return result
    }

    func cancelRefresh() {
        revision &+= 1
        refresh?.cancel(); refresh = nil
    }

    func clear() { cancelRefresh(); snapshot = nil; updatedAt = nil; chosen = nil; guess = nil }
    func invalidate() { updatedAt = nil }

    func noteChosen(_ id: UUID) { chosen = id }
    func forgetChosen(_ id: UUID) { if chosen == id { chosen = nil } }

    func noteFocused(_ id: UUID) {
        chosen = nil
        guard let snapshot, let window = snapshot.windows.first(where: { $0.id == id }) else { return }
        self.snapshot = WindowCatalog.Snapshot(windows: [window] + snapshot.windows.filter { $0.id != id }, current: id,
                                              completeness: snapshot.completeness)
    }

    /// The window that really was in front when the switcher opened, read after the guess
    /// in `readySnapshot`. The guess goes back to where it stood and the reading takes the
    /// front, behind the window `selected` meanwhile once that one's focus is recorded.
    func noteLeft(_ window: SwitcherWindow, selected: UUID? = nil) {
        guard let snapshot else { return }
        var windows = snapshot.windows
        if let guess, guess.id != window.id, let from = windows.firstIndex(where: { $0.id == guess.id }) {
            let wrong = windows.remove(at: from)
            windows.insert(wrong, at: windows.firstIndex { $0.id == guess.behind }.map { $0 + 1 } ?? from)
        }
        guess = nil
        // A reading of its own app replaces the choice, as any recorded focus does.
        if selected == nil, windows.first(where: { $0.id == chosen })?.pid == window.pid { chosen = nil }
        let row = windows.first { $0.id == window.id } ?? window
        windows.removeAll { $0.id == window.id }
        let recorded = selected != nil && windows.first?.id == selected
        windows.insert(row, at: recorded ? 1 : 0)
        self.snapshot = WindowCatalog.Snapshot(windows: windows, current: recorded ? snapshot.current : window.id,
                                               completeness: snapshot.completeness)
    }

    func needsRefresh(at now: ContinuousClock.Instant = .now) -> Bool {
        guard let updatedAt else { return true }
        return updatedAt.duration(to: now) >= .seconds(5)
    }

    func readySnapshot(frontPID: pid_t?, livePIDs: Set<pid_t>? = nil) -> WindowCatalog.Snapshot? {
        // Freshness controls discovery, not presentation. Typing deliberately
        // pauses scans; the last inventory is still useful immediately afterward.
        guard let snapshot else { return nil }
        var windows = snapshot.windows.filter { livePIDs?.contains($0.pid) ?? true }
        // An app can come forward unrecorded: scans pause while typing, and a
        // keystroke retires a pending activation. The window chosen in it leads all
        // the same, ahead of the app's other windows, so the next row is the one
        // used before it rather than an arbitrary one.
        let current = windows.first { $0.id == chosen && $0.pid == frontPID }
            ?? windows.first { $0.id == snapshot.current && $0.pid == frontPID }
            ?? windows.first { $0.pid == frontPID }
        guess = nil
        if let current, windows.first?.id != current.id {
            noteFocused(current.id)
            if let from = snapshot.windows.firstIndex(where: { $0.id == current.id }), from > 0 {
                guess = (current.id, snapshot.windows[from - 1].id)
            }
            windows = [current] + windows.filter { $0.id != current.id }
        }
        return WindowCatalog.Snapshot(windows: windows, current: current?.id, completeness: snapshot.completeness)
    }
}

/// Apps the switcher asked macOS to bring forward that are not reported in front yet.
/// Until then `NSWorkspace` still names the app being left, and the report can arrive
/// after the next Command–Tab has opened the list or chosen another window.
struct WindowSwitchFrontRequests {
    private var pending: [(pid: pid_t, at: ContinuousClock.Instant)] = []

    /// macOS may never bring an app forward; what it reports counts again after a second.
    private func awaited(_ now: ContinuousClock.Instant) -> [(pid: pid_t, at: ContinuousClock.Instant)] {
        pending.filter { $0.at.duration(to: now) < .seconds(1) }
    }

    mutating func requested(_ pid: pid_t, at now: ContinuousClock.Instant = .now) { pending = awaited(now) + [(pid, now)] }
    mutating func withdraw(_ pid: pid_t) { pending.removeAll { $0.pid == pid } }

    /// Whether an app reported in front comes forward on a request made here, which must
    /// neither close a list opened since nor cancel a selection made since. Requests are
    /// answered in order; any other app coming forward ends the wait for all of them.
    mutating func activated(_ pid: pid_t, at now: ContinuousClock.Instant = .now) -> Bool {
        pending = awaited(now)
        guard let answered = pending.firstIndex(where: { $0.pid == pid }) else { pending = []; return false }
        pending.removeSubrange(...answered)
        return true
    }

    /// The app to take as being in front: the last one asked for, else the one reported.
    func front(_ reported: pid_t?, at now: ContinuousClock.Instant = .now) -> pid_t? { awaited(now).last?.pid ?? reported }
}

/// Released invocations never present late data; held invocations require rows.
struct WindowSwitchPresentation {
    private(set) var sessionID: UInt64?
    private(set) var ready = false
    private(set) var delayElapsed = false
    private(set) var released = false

    var shouldShow: Bool { sessionID != nil && ready && delayElapsed && !released }

    mutating func begin(_ id: UInt64, ready: Bool) {
        sessionID = id; self.ready = ready; delayElapsed = false; released = false
    }
    mutating func loaded(_ id: UInt64) { if sessionID == id { ready = true } }
    mutating func elapsed(_ id: UInt64) { if sessionID == id { delayElapsed = true } }
    mutating func release(_ id: UInt64) { if sessionID == id { released = true } }
    mutating func cancel(_ id: UInt64) { if sessionID == id { sessionID = nil } }
}
