import AppKit
import ApplicationServices

struct SwitcherApplication: Sendable {
    let pid: pid_t
    let name: String
    let hidden: Bool

    static func eligible(policy: NSApplication.ActivationPolicy, terminated: Bool, bundleURL: URL?) -> Bool {
        // Widgets, XPC services and network helpers are not user-switchable apps.
        !terminated && policy == .regular && bundleURL?.pathExtension == "app"
    }

    @MainActor static func running(_ application: NSRunningApplication) -> SwitcherApplication? {
        guard eligible(policy: application.activationPolicy, terminated: application.isTerminated, bundleURL: application.bundleURL) else { return nil }
        return SwitcherApplication(pid: application.processIdentifier, name: application.localizedName ?? "Application", hidden: application.isHidden)
    }
}

/// Display metadata never exposes the catalog's retained native AX handles.
struct SwitcherWindow: Identifiable, Equatable, Sendable {
    static let overlayIdentifier = "frog.window-switcher"
    let id: UUID
    let pid: pid_t
    let appName: String
    let title: String
    let minimized: Bool
    let hidden: Bool
    var windowID: CGWindowID? = nil
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
        var windowID: @Sendable (AXUIElement) -> CGWindowID? = { WindowSpaceBridge.windowID($0) }
        var offSpaceWindows: @Sendable (Set<pid_t>) -> [WindowSpaceBridge.Window] = { WindowSpaceBridge.offSpaceWindows(owners: $0) }
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
    // AX handles are immutable CF references. The store publishes only a completed
    // inventory; discovery never holds its lock across an AX call. Activation uses
    // its own serial executor so an unrelated owner's scan cannot delay selection.
    struct Target: @unchecked Sendable {
        let id: UUID
        let pid: pid_t
        let element: AXUIElement?
        var windowID: CGWindowID? = nil
    }
    private final class ActivationTargets: @unchecked Sendable {
        private let lock = NSLock()
        private var targets: [UUID: Target] = [:]
        private var raised: [UUID] = []
        func replace(_ values: [Target]) { lock.withLock { targets = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }) } }
        func target(_ id: UUID) -> Target? { lock.withLock { targets[id] } }
        func noteRaised(_ id: UUID) {
            lock.withLock {
                raised.removeAll { $0 == id }; raised.append(id)
                if raised.count > 256 { raised.removeFirst(raised.count - 256) }
            }
        }
        func takeRaised() -> [UUID] { lock.withLock { defer { raised = [] }; return raised } }
    }
    private nonisolated let activationTargets = ActivationTargets()
    private nonisolated let activator: WindowActivationExecutor
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

    init(reader: Reader = Reader(), writer: WindowActivationExecutor.Writer = .init(),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.reader = reader; self.now = now
        activator = WindowActivationExecutor(writer: writer)
    }

    private func identity(_ element: AXUIElement?, pid: pid_t, windowID: CGWindowID? = nil) -> UUID {
        if let index = targets.firstIndex(where: { target in
            guard target.pid == pid else { return false }
            if let windowID, target.windowID == windowID { return true }
            return element.flatMap { element in target.element.map { CFEqual($0, element) } } ?? false
        }) {
            let old = targets[index]
            targets[index] = Target(id: old.id, pid: pid, element: element ?? old.element, windowID: windowID ?? old.windowID)
            return old.id
        }
        let id = UUID()
        targets.append(Target(id: id, pid: pid, element: element, windowID: windowID))
        return id
    }

    func noteFocus(pid: pid_t) -> UUID? {
        guard reader.isTrusted(), !Task.isCancelled else { return nil }
        guard let element = reader.focusedWindow(pid), !Task.isCancelled else { return nil }
        mergeRaisedRecency()
        let id = identity(element, pid: pid, windowID: reader.windowID(element))
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
        mergeRaisedRecency()
        let previousTargets = targets
        let previousRecent = recent
        let timestamp = now()
        var known: [UUID: KnownWindow] = [:]
        var completeness = Snapshot.Completeness.complete
        var windows: [SwitcherWindow] = []
        var current: UUID?
        func retain(_ app: SwitcherApplication, element: AXUIElement? = nil, unreadElements: ArraySlice<AXUIElement>? = nil) {
            completeness = .partial
            // Only previously described windows can be retained, for at most 30s.
            // A successful empty list (or a departed owner) never reaches this path.
            for target in previousTargets where target.pid == app.pid {
                if let element, target.element.map({ !CFEqual($0, element) }) ?? true { continue }
                if let unreadElements, !unreadElements.contains(where: { candidate in target.element.map { CFEqual($0, candidate) } ?? false }) { continue }
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
            windowLoop: for (index, element) in elements.enumerated() {
                if Task.isCancelled { break }
                let metadata: Metadata
                switch reader.metadata(element) {
                case .success(let value): metadata = value
                case .failure(.cannotComplete):
                    // A stalled owner's remaining windows share the same AX
                    // connection. Do not multiply one timeout by its window count.
                    retain(app, unreadElements: elements[index...])
                    break windowLoop
                case .failure:
                    retain(app, element: element)
                    continue
                }
                guard metadata.role == kAXWindowRole else { continue }
                if metadata.identifier == SwitcherWindow.overlayIdentifier { continue }
                if ["AXFloatingWindow", "AXSystemFloatingWindow"].contains(metadata.subrole ?? "") { continue }
                let nativeID = reader.windowID(element)
                let id = identity(element, pid: app.pid, windowID: nativeID)
                guard !windows.contains(where: { $0.id == id }) else { continue }
                let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let window = SwitcherWindow(id: id, pid: app.pid, appName: app.name,
                    title: title.isEmpty ? "Untitled window" : title,
                    minimized: metadata.minimized, hidden: app.hidden, windowID: nativeID)
                windows.append(window)
                known[id] = KnownWindow(window: window, readAt: timestamp)
                if let focused, CFEqual(focused, element) { current = id }
            }
        }
        if !Task.isCancelled {
            let owners = Dictionary(uniqueKeysWithValues: applications.map { ($0.pid, $0) })
            for server in reader.offSpaceWindows(Set(owners.keys)) {
                guard !Task.isCancelled else { break }
                guard let app = owners[server.pid] else { continue }
                let id = identity(nil, pid: server.pid, windowID: server.id)
                guard !windows.contains(where: { $0.id == id }) else { continue }
                let title = server.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let window = SwitcherWindow(id: id, pid: server.pid, appName: app.name,
                    title: title.flatMap { $0.isEmpty ? nil : $0 } ?? lastKnown[id]?.window.title ?? "Window on another Desktop",
                    minimized: lastKnown[id]?.window.minimized ?? false, hidden: app.hidden, windowID: server.id)
                windows.append(window)
                known[id] = KnownWindow(window: window, readAt: timestamp)
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
        activationTargets.replace(targets)
        return Snapshot(windows: windows, current: current, completeness: completeness)
    }

    nonisolated func bringApplicationForward(id: UUID, isCurrent: @escaping @Sendable () -> Bool = { true }) async -> Bool {
        guard !Task.isCancelled, isCurrent(), let target = activationTargets.target(id) else { return false }
        return await activator.bringForward(target, isCurrent: isCurrent)
    }

    nonisolated func raise(id: UUID, isCurrent: @escaping @Sendable () -> Bool = { true }) async -> Bool {
        guard !Task.isCancelled, isCurrent(), let target = activationTargets.target(id) else { return false }
        let raised = await activator.raise(target, isCurrent: isCurrent)
        if raised { activationTargets.noteRaised(id) }
        return raised
    }

    nonisolated func prepareActivation(id: UUID, isCurrent: @escaping @Sendable () -> Bool = { true },
                                      willChangeSpace: @escaping @Sendable () async -> Void = {}) async -> Bool {
        guard !Task.isCancelled, isCurrent(), let target = activationTargets.target(id) else { return false }
        return await activator.prepare(target, isCurrent: isCurrent, willChangeSpace: willChangeSpace)
    }

    private func mergeRaisedRecency() {
        for id in activationTargets.takeRaised() where targets.contains(where: { $0.id == id }) {
            recent.removeAll { $0 == id }; recent.insert(id, at: 0)
        }
    }
}
