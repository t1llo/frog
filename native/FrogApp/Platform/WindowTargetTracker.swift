import AppKit

/// The app whose window a Frog panel arranges: the app in front, or, while Frog itself is in
/// front, the app that was in front before it. Watches app activation only while started.
@MainActor
final class WindowTargetTracker {
    private(set) var remembered: pid_t?
    private var observer: NSObjectProtocol?
    private let own = ProcessInfo.processInfo.processIdentifier

    var running: Bool { observer != nil }

    func start() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != own { remembered = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != self.own else { return }
                self.remembered = app.processIdentifier
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        remembered = nil
    }

    /// The target now, or nil when there is none or the remembered app has quit.
    var target: pid_t? {
        let remembered = remembered.flatMap { pid in NSRunningApplication(processIdentifier: pid).map { _ in pid } }
        return Self.target(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, remembered: remembered, own: own)
    }

    static func target(frontmost: pid_t?, remembered: pid_t?, own: pid_t) -> pid_t? {
        if let frontmost, frontmost != own { return frontmost }
        if let remembered, remembered != own { return remembered }
        return nil
    }
}
