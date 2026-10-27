import AppKit
import Carbon
import IOKit
import SwiftUI

/// macOS secure keyboard entry. While an app holds it — normally for a focused password
/// field, even in a window left in the background — key events reach that app only. Event
/// taps such as the window switcher's receive nothing, and no public API lifts that.
enum SecureInput {
    struct Holder: Equatable {
        var pid: pid_t?
        var name: String?
        /// The user is at the prompt itself; nothing needs explaining yet.
        var frontmost = false
    }

    /// The application a holding process belongs to, and the name to show for it.
    struct Identity: Equatable {
        var application: URL?
        var name: String?
    }

    /// Naming the holder asks the workspace and the file system, and the switcher asks who
    /// holds the keyboard several times a second. The answer is kept while the same process
    /// holds it; a process that could not be named yet is asked about again.
    struct IdentityCache {
        private var known: (pid: pid_t, identity: Identity)?

        mutating func identity(of pid: pid_t, lookup: (pid_t) -> Identity) -> Identity {
            if let known, known.pid == pid { return known.identity }
            let identity = lookup(pid)
            known = identity.name == nil ? nil : (pid, identity)
            return identity
        }

        /// Secure input ended, so the next holder is another episode, perhaps of a reused pid.
        mutating func forget() { known = nil }
    }

    @MainActor private static var identities = IdentityCache()

    @MainActor static func holder(frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> Holder? {
        guard IsSecureEventInputEnabled() else { identities.forget(); return nil }
        guard let pid = holderPID() else { return Holder() }
        let holder = identities.identity(of: pid, lookup: identity)
        let front = frontmost.map {
            $0.processIdentifier == pid || (holder.application != nil && $0.bundleURL.map(application) == holder.application)
        } ?? false
        return Holder(pid: pid, name: holder.name, frontmost: front)
    }

    private static func identity(of pid: pid_t) -> Identity {
        let app = NSRunningApplication(processIdentifier: pid)
        let bundle = app?.bundleURL.map(application)
        return Identity(application: bundle, name: bundle.map(name) ?? app?.localizedName)
    }

    /// The window server records the owning process in the console session's description.
    private static func holderPID() -> pid_t? {
        let key = "kCGSSessionSecureInputPID"
        if let pid = (CGSessionCopyCurrentDictionary() as? [String: Any])?[key] as? Int, pid > 0 { return pid_t(pid) }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        return users?.compactMap { $0[key] as? Int }.first { $0 > 0 }.map { pid_t($0) }
    }

    /// A browser-based app takes secure input from a helper nested in its bundle; name the app.
    static func application(_ bundle: URL) -> URL {
        let path = bundle.path
        guard let end = path.range(of: ".app/")?.lowerBound else { return bundle.standardizedFileURL }
        return URL(fileURLWithPath: String(path[..<end]) + ".app").standardizedFileURL
    }

    private static func name(_ application: URL) -> String {
        let name = FileManager.default.displayName(atPath: application.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func summary(_ holder: Holder) -> String {
        "Window switcher paused — \(holder.name ?? "another app") is asking for a password"
    }

    static func status(_ holder: Holder) -> String {
        "Paused — \(holder.name ?? "another app") is asking for a password. macOS hides the keyboard from every other app until you enter it or close that window."
    }
}

/// When to say why the switcher is silent. A prompt the user is typing into needs no
/// explanation; one left waiting in the background gets one, and a rare reminder.
struct SecureInputNotice {
    static let settle: TimeInterval = 1.5
    static let reminder: TimeInterval = 300
    private var waitingSince: Date?
    private var shownAt: Date?

    /// Every poll. True when the notice is due now.
    mutating func poll(_ holder: SecureInput.Holder?, own: pid_t, now: Date) -> Bool {
        guard let holder, holder.pid != own, !holder.frontmost else {
            waitingSince = nil
            if holder == nil { shownAt = nil }
            return false
        }
        let since = waitingSince ?? now
        waitingSince = since
        guard shownAt == nil, now.timeIntervalSince(since) >= Self.settle else { return false }
        shownAt = now
        return true
    }

    /// Another app came forward: the moment a switch that Frog could not see is noticed.
    mutating func applicationChanged(now: Date) -> Bool {
        guard waitingSince != nil, let shownAt, now.timeIntervalSince(shownAt) >= Self.reminder else { return false }
        self.shownAt = now
        return true
    }
}

/// Non-activating and click-through, like the processing indicator.
@MainActor
final class SecureInputNoticePanel {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ message: String) {
        dismissal?.cancel()
        if panel == nil {
            let created = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            created.level = .floating
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.ignoresMouseEvents = true
            created.hidesOnDeactivate = false
            created.isReleasedWhenClosed = false
            panel = created
        }
        guard let panel else { return }
        let host = NSHostingView(rootView: HStack(spacing: 8) {
            Image(systemName: "lock").foregroundStyle(FrogStyle.warning)
            Text(message).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }.padding(.horizontal, 14).frame(height: 36).frogPanel(pill: true))
        let size = host.fittingSize
        panel.contentView = host
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 24,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.hide()
        }
    }

    func hide() { dismissal?.cancel(); dismissal = nil; panel?.orderOut(nil) }
}
