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
    enum Reading<Value> {
        case success(Value)
        case failure(AXError)
    }
    /// The OS boundary keeps failed AX reads distinct from successful empty lists.
    struct Reader: Sendable {
        var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
        var windows: @Sendable (pid_t) -> Reading<[AXUIElement]> = { pid in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            guard error == .success else { return .failure(error) }
            guard let windows = value as? [AXUIElement] else { return .failure(.failure) }
            return .success(windows)
        }
        var focusedWindow: @Sendable (pid_t) -> AXUIElement? = { pid in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            return AXRead.element(app, kAXFocusedWindowAttribute)
        }
        var metadata: @Sendable (AXUIElement) -> Reading<Metadata> = { element in
            AXUIElementSetMessagingTimeout(element, 0.1)
            let names = [kAXRoleAttribute, kAXIdentifierAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute]
            var result: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result)
            // Some applications support individual attributes but not the batch
            // API. Preserve that compatibility, without retrying a timed-out app.
            guard error != .cannotComplete else { return .failure(error) }
            let values: [Any]
            if error == .success, let batch = result as? [Any], batch.count == names.count {
                values = batch
            } else {
                var individual: [Any] = []
                for name in names {
                    guard !Task.isCancelled else { return .failure(.cannotComplete) }
                    var value: CFTypeRef?
                    let failure = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                    if failure == .cannotComplete { return .failure(failure) }
                    individual.append(value ?? kCFNull as Any)
                }
                values = individual
            }
            // Multi-attribute reads can succeed while individual attributes time out.
            for value in values where CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
                let axValue = value as! AXValue
                if AXValueGetType(axValue) == .axError {
                    var error = AXError.success
                    if AXValueGetValue(axValue, .axError, &error), error == .cannotComplete { return .failure(error) }
                }
            }
            guard let role = values[0] as? String else { return .failure(.failure) }
            return .success(Metadata(role: role, identifier: values[1] as? String,
                subrole: values[2] as? String, title: values[3] as? String, minimized: values[4] as? Bool == true))
        }
    }
    struct Metadata {
        var role: String? = kAXWindowRole
        var identifier: String? = nil
        var subrole: String? = nil
        var title: String? = nil
        var minimized = false
    }
    struct Snapshot: Sendable {
        enum Completeness: Sendable { case complete, partial, unavailable, cancelled }
        let windows: [SwitcherWindow]
        let current: UUID?
        var completeness: Completeness = .complete
        var isPublishable: Bool { completeness == .complete || completeness == .partial }
    }
    private struct Target {
        let id: UUID
        let pid: pid_t
        let element: AXUIElement
    }
    private var targets: [Target] = []
    private var recent: [UUID] = []
    private var snapshotIDs = Set<UUID>()
    private let reader: Reader
    private let now: @Sendable () -> ContinuousClock.Instant
    private struct KnownWindow {
        let window: SwitcherWindow
        let readAt: ContinuousClock.Instant
    }
    private var lastKnown: [UUID: KnownWindow] = [:]

    init(reader: Reader = Reader(), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.reader = reader; self.now = now
    }

    private func identity(_ element: AXUIElement, pid: pid_t) -> UUID {
        if let target = targets.first(where: { $0.pid == pid && CFEqual($0.element, element) }) { return target.id }
        let id = UUID()
        targets.append(Target(id: id, pid: pid, element: element))
        return id
    }

    func noteFocus(pid: pid_t) -> UUID? {
        guard reader.isTrusted(), !Task.isCancelled else { return nil }
        guard let element = reader.focusedWindow(pid), !Task.isCancelled else { return nil }
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
        guard !Task.isCancelled else { return Snapshot(windows: [], current: nil, completeness: .cancelled) }
        guard reader.isTrusted() else { return Snapshot(windows: [], current: nil, completeness: .unavailable) }
        let previousTargets = targets
        let previousRecent = recent
        let timestamp = now()
        var known: [UUID: KnownWindow] = [:]
        var completeness = Snapshot.Completeness.complete
        var windows: [SwitcherWindow] = []
        var current: UUID?
        func retain(_ app: SwitcherApplication, element: AXUIElement? = nil) {
            completeness = .partial
            // Only previously described windows can be retained, for at most 30s.
            // A successful empty list (or a departed owner) never reaches this path.
            for target in previousTargets where target.pid == app.pid {
                if let element, !CFEqual(target.element, element) { continue }
                guard let old = lastKnown[target.id], old.readAt.duration(to: timestamp) < .seconds(30),
                      !windows.contains(where: { $0.id == target.id }) else { continue }
                windows.append(old.window)
                known[target.id] = old
            }
        }
        // Inspect the foreground app first, but do not group away its individual windows.
        let applications = applications.sorted { ($0.pid == frontPID ? 0 : 1) < ($1.pid == frontPID ? 0 : 1) }
        for app in applications {
            if Task.isCancelled { break }
            guard case .success(let elements) = reader.windows(app.pid) else { retain(app); continue }
            guard !Task.isCancelled else { break }
            let focused = app.pid == frontPID ? reader.focusedWindow(app.pid) : nil
            for element in elements {
                if Task.isCancelled { break }
                guard case .success(let metadata) = reader.metadata(element) else { retain(app, element: element); continue }
                guard metadata.role == kAXWindowRole else { continue }
                if metadata.identifier == SwitcherWindow.overlayIdentifier { continue }
                if ["AXFloatingWindow", "AXSystemFloatingWindow"].contains(metadata.subrole ?? "") { continue }
                let id = identity(element, pid: app.pid)
                guard !windows.contains(where: { $0.id == id }) else { continue }
                let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let window = SwitcherWindow(id: id, pid: app.pid, appName: app.name,
                    title: title.isEmpty ? "Untitled window" : title,
                    minimized: metadata.minimized, hidden: app.hidden)
                windows.append(window)
                known[id] = KnownWindow(window: window, readAt: timestamp)
                if let focused, CFEqual(focused, element) { current = id }
            }
        }
        guard !Task.isCancelled else {
            targets = previousTargets
            return Snapshot(windows: [], current: nil, completeness: .cancelled)
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
            return Snapshot(windows: [], current: nil, completeness: .cancelled)
        }
        snapshotIDs = live
        // Bound fallback metadata separately from the current live inventory.
        lastKnown = Dictionary(uniqueKeysWithValues: windows.prefix(256).compactMap { window in known[window.id].map { (window.id, $0) } })
        return Snapshot(windows: windows, current: current, completeness: completeness)
    }

    func bringApplicationForward(id: UUID) -> Bool {
        guard !Task.isCancelled, AXIsProcessTrusted(), let target = targets.first(where: { $0.id == id }) else { return false }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        return AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
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
