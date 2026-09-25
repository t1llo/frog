import AppKit
import ApplicationServices

struct SwitcherApplication: Sendable {
    let pid: pid_t
    let name: String
    let hidden: Bool
}

/// AX references stay on the catalog actor, apart from immutable display metadata.
struct SwitcherWindow: Identifiable, Equatable, Sendable {
    static let overlayIdentifier = "frog.window-switcher"
    let id: UUID
    let pid: pid_t
    let appName: String
    let title: String
    let minimized: Bool
    let hidden: Bool
}

actor WindowCatalog {
    struct Snapshot: Sendable {
        let windows: [SwitcherWindow]
        let current: UUID?
    }
    private struct Target {
        let id: UUID
        let pid: pid_t
        let element: AXUIElement
    }
    private var targets: [Target] = []
    private var recent: [UUID] = []
    private var snapshotIDs = Set<UUID>()

    private func identity(_ element: AXUIElement, pid: pid_t) -> UUID {
        if let target = targets.first(where: { $0.pid == pid && CFEqual($0.element, element) }) { return target.id }
        let id = UUID()
        targets.append(Target(id: id, pid: pid, element: element))
        return id
    }

    func noteFocus(pid: pid_t) -> UUID? {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let element = AXRead.element(app, kAXFocusedWindowAttribute), !Task.isCancelled else { return nil }
        let id = identity(element, pid: pid)
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 256 { recent.removeLast(recent.count - 256) }
        // Pin the last complete snapshot for pending activation, while bounding
        // focus-only references if no new switcher scan is requested for a while.
        if targets.count > snapshotIDs.count + recent.count {
            let retained = snapshotIDs.union(recent)
            targets.removeAll { !retained.contains($0.id) }
        }
        return id
    }

    func snapshot(applications: [SwitcherApplication], frontPID: pid_t?) -> Snapshot {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return Snapshot(windows: [], current: nil) }
        let previousTargets = targets
        let previousRecent = recent
        var windows: [SwitcherWindow] = []
        var current: UUID?
        // Inspect the foreground app first, but do not group away its individual windows.
        let applications = applications.sorted { ($0.pid == frontPID ? 0 : 1) < ($1.pid == frontPID ? 0 : 1) }
        for app in applications {
            if Task.isCancelled { break }
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, 0.1)
            let focused = app.pid == frontPID ? AXRead.element(application, kAXFocusedWindowAttribute) : nil
            guard let elements = AXRead.attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for element in elements {
                if Task.isCancelled { break }
                AXUIElementSetMessagingTimeout(element, 0.1)
                // Fetch display metadata in one IPC rather than six sequential AX calls.
                let names = [kAXRoleAttribute, kAXIdentifierAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute]
                var result: CFArray?
                let success = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success
                let values = success ? result as? [Any] : nil
                func value(_ index: Int) -> Any? {
                    if let values, values.count == names.count { return values[index] }
                    guard !Task.isCancelled else { return nil }
                    return AXRead.attribute(element, names[index])
                }
                guard value(0) as? String == kAXWindowRole else { continue }
                if value(1) as? String == SwitcherWindow.overlayIdentifier { continue }
                let subrole = value(2) as? String
                if ["AXFloatingWindow", "AXSystemFloatingWindow"].contains(subrole ?? "") { continue }
                let id = identity(element, pid: app.pid)
                guard !windows.contains(where: { $0.id == id }) else { continue }
                let title = (value(3) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                windows.append(SwitcherWindow(id: id, pid: app.pid, appName: app.name,
                    title: title.isEmpty ? "Untitled window" : title,
                    minimized: value(4) as? Bool == true, hidden: app.hidden))
                if let focused, CFEqual(focused, element) { current = id }
            }
        }
        guard !Task.isCancelled else {
            targets = previousTargets
            return Snapshot(windows: [], current: nil)
        }
        let live = Set(windows.map(\.id))
        targets.removeAll { !live.contains($0.id) }
        recent.removeAll { !live.contains($0) }
        if let current { recent.removeAll { $0 == current }; recent.insert(current, at: 0) }
        let ranks = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element, $0.offset) })
        windows = windows.enumerated().sorted {
            let lhs = ranks[$0.element.id] ?? Int.max
            let rhs = ranks[$1.element.id] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
        guard !Task.isCancelled else {
            targets = previousTargets; recent = previousRecent
            return Snapshot(windows: [], current: nil)
        }
        snapshotIDs = live
        return Snapshot(windows: windows, current: current)
    }

    func raise(id: UUID) -> Bool {
        guard !Task.isCancelled, AXIsProcessTrusted(), let target = targets.first(where: { $0.id == id }) else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(target.element, &pid) == .success, pid == target.pid,
              AXRead.string(target.element, kAXRoleAttribute) == kAXWindowRole else { return false }
        if AXRead.boolean(target.element, kAXMinimizedAttribute) == true {
            guard !Task.isCancelled else { return false }
            guard AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else { return false }
        }
        guard !Task.isCancelled else { return false }
        let raised = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        guard !Task.isCancelled else { return false }
        _ = AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard !Task.isCancelled else { return false }
        if raised == .success { recent.removeAll { $0 == id }; recent.insert(id, at: 0) }
        return raised == .success
    }
}
