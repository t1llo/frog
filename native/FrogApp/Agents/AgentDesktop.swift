import AppKit
import ApplicationServices
import FrogCore

/// What the window and app commands read and change. The defaults are this Mac's; tests give
/// fixtures instead, so no real window moves.
struct AgentDesktop {
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    /// Running apps a person switches between, Frog aside.
    var apps: @MainActor () -> [AgentApp] = { AgentDesktop.runningApps() }
    /// The app in front, which may be Frog.
    var frontmost: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    /// The windows of these apps on the current Desktop, front to back. Blocking: called off the main actor.
    var windows: @Sendable (_ apps: [AgentApp], _ displays: [WindowDisplay], _ frontmost: pid_t?) -> [AgentWindow] = {
        AgentDesktop.scan($0, displays: $1, frontmost: $2)
    }
    var displays: @MainActor () -> [WindowDisplay] = { WindowDisplays.current() }
    var macOS: () -> MacWindowManagerSettings = { MacWindowManagerReader.read() }
    /// Moves windows and keeps what Restore returns to; nil for the one shortcuts use.
    var manager: WindowManager?
    var focus: @MainActor (AgentWindow) async -> Bool = { await AgentDesktop.bringForward($0) }
    /// An installed app, by bundle id or by the name Finder shows.
    var findApp: @MainActor (String) async -> URL? = { await AgentDesktop.installedApp($0) }
    /// Opens an app, or brings it forward when it runs.
    var open: @MainActor (URL) async throws -> Void = { try await ApplicationLauncher().open($0) }
}

/// A running app, as `frog apps list` shows it.
struct AgentApp: Encodable, Sendable {
    let name: String
    let bundleId: String?
    let pid: pid_t
    let active: Bool
    let hidden: Bool
    var url: URL?

    private enum CodingKeys: String, CodingKey { case name, bundleId, pid, active, hidden }
}

/// A rectangle in whole points, for output.
struct AgentFrame: Encodable, Equatable {
    let x: Int, y: Int, width: Int, height: Int

    init(_ rect: CGRect) {
        x = Int(rect.minX.rounded()); y = Int(rect.minY.rounded())
        width = Int(rect.width.rounded()); height = Int(rect.height.rounded())
    }

    var text: String { "\(width)×\(height) at \(x), \(y)" }
}

/// A window, as `frog windows list` shows it. Its frame is in Accessibility's coordinates:
/// points from the top left of the main display.
struct AgentWindow: Encodable, Sendable {
    let app: String
    let title: String
    var frame: CGRect
    /// 1 for the first display in `frog windows displays`.
    var display: Int
    var minimized: Bool
    let hidden: Bool
    /// It has keyboard focus: its app's focused window, in the app in front.
    var focused = false
    /// Its app's focused window, the one `--app` picks.
    var appFocused = false
    let handle: WindowHandle
    /// Its WindowServer number, which activation uses to find its Desktop; nil when macOS lends none.
    var number: CGWindowID?

    /// The id agents pass back, the same number restore history keys the window by.
    var id: UInt32 { handle.key.number }
    var pid: pid_t { handle.key.pid }
    /// "Safari — “Docs”", or the app alone for an untitled window.
    var name: String { title.isEmpty ? app : "\(app) — “\(title)”" }

    private enum CodingKeys: String, CodingKey { case id, app, pid, title, frame, display, minimized, hidden, focused }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(app, forKey: .app)
        try container.encode(pid, forKey: .pid)
        try container.encode(title, forKey: .title)
        try container.encode(AgentFrame(frame), forKey: .frame)
        try container.encode(display, forKey: .display)
        try container.encode(minimized, forKey: .minimized)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(focused, forKey: .focused)
    }
}

extension AgentDesktop {
    /// 1 for the first display, in the order window actions walk them; 0 when there is none.
    static func displayNumber(of frame: CGRect, in displays: [WindowDisplay]) -> Int {
        WindowGeometry.displayIndex(for: frame, displays: displays.map(\.frame)).map { $0 + 1 } ?? 0
    }

    /// Windows in WindowServer's order, front first. Those it does not show, minimized or of a
    /// hidden app, keep their order after them.
    static func frontToBack(_ windows: [AgentWindow], order: [CGWindowID: Int]) -> [AgentWindow] {
        windows.enumerated().sorted { left, right in
            let lhs = left.element.number.flatMap { order[$0] } ?? Int.max
            let rhs = right.element.number.flatMap { order[$0] } ?? Int.max
            return lhs == rhs ? left.offset < right.offset : lhs < rhs
        }.map(\.element)
    }

    @MainActor static func runningApps() -> [AgentApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != own,
                  SwitcherApplication.eligible(policy: app.activationPolicy, terminated: app.isTerminated, bundleURL: app.bundleURL) else { return nil }
            let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Application"
            return AgentApp(name: name, bundleId: app.bundleIdentifier, pid: app.processIdentifier, active: app.isActive,
                            hidden: app.isHidden, url: app.bundleURL)
        }
    }

    /// Reads the windows through Accessibility, as the window switcher does: switchable windows
    /// only, each app given 0.1 s to answer.
    static func scan(_ apps: [AgentApp], displays: [WindowDisplay], frontmost: pid_t?) -> [AgentWindow] {
        let reader = WindowCatalog.Reader()
        let access = AXWindowAccess()
        var windows: [AgentWindow] = []
        for app in apps {
            guard case .success(let elements) = reader.windows(app.pid) else { continue }
            let focused = reader.focusedWindow(app.pid)
            for element in elements {
                guard case .success(let metadata) = reader.metadata(element), metadata.isSwitchable else { continue }
                let number = reader.windowID(element)
                let key = number.map { WindowKey(pid: app.pid, number: $0) } ?? AXWindowAccess.key(of: element, pid: app.pid)
                let handle = WindowHandle(key: key, element: element)
                guard let frame = access.frame(of: handle) else { continue }
                let isFocused = focused.map { CFEqual($0, element) } ?? false
                windows.append(AgentWindow(app: app.name, title: metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                           frame: frame, display: displayNumber(of: frame, in: displays), minimized: metadata.minimized,
                                           hidden: app.hidden, focused: isFocused && app.pid == frontmost, appFocused: isFocused,
                                           handle: handle, number: number))
            }
        }
        return frontToBack(windows, order: onScreenOrder())
    }

    /// WindowServer's on-screen windows, front first, by number.
    private static func onScreenOrder() -> [CGWindowID: Int] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var order: [CGWindowID: Int] = [:]
        for (index, row) in rows.enumerated() {
            if let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value, order[number] == nil { order[number] = index }
        }
        return order
    }

    /// Brings the window and its app forward the way the window switcher does: its Desktop is
    /// selected, it is unminimized and raised, and its app activated.
    @MainActor static func bringForward(_ window: AgentWindow) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return false }
        let executor = WindowActivationExecutor(writer: .init())
        let target = WindowCatalog.Target(id: UUID(), pid: window.pid, element: window.handle.element, windowID: window.number)
        let current: @Sendable () -> Bool = { true }
        return await WindowActivation.perform(
            raise: { await executor.raise(target, isCurrent: current) },
            request: {
                if app.isHidden { _ = app.unhide() }
                return app.activate(options: [])
            },
            bringForward: { await executor.bringForward(target, isCurrent: current) },
            isFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid },
            prepare: { await executor.prepare(target, isCurrent: current) },
            raiseAfterRequest: { await executor.raise(target, isCurrent: current, requested: true) })
    }

    /// An installed app by bundle id, else by the name Finder shows or its bundle's own names,
    /// from the list the command bar searches.
    @MainActor static func installedApp(_ text: String) async -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: text) { return url }
        let store = ApplicationCatalogStore.shared
        let wanted = text.lowercased()
        for rule in await store.load() {
            guard let path = rule.action?.applicationPath else { continue }
            let names = [rule.name] + (store.alternativeNames[path] ?? [])
            if names.contains(where: { $0.lowercased() == wanted }) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}
