import AppKit
import ApplicationServices
import FrogCore

/// Keep launching/reopening an application separate from shortcut delivery.
@MainActor
struct ApplicationLauncher {
    var resolve: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    var bundleIdentifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
    var open: (URL) async throws -> Void = { url in
        // Launching does not synthesize keystrokes, so it need not wait for key-up.
        try Task.checkCancellation()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        // Launch Services sends reopen even when the process already exists.
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try Task.checkCancellation()
        app.unhide()
        let activated = await WindowActivation.perform(raise: { true }, request: { app.activate(options: []) }, bringForward: {
            await ApplicationForeground.shared.request(pid: app.processIdentifier)
        }, isFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier })
        try Task.checkCancellation()
        guard activated else { throw FrogError.message("The application opened, but macOS did not bring it forward. Check Accessibility permission in Settings.") }
    }

    func launch(_ rule: Rule) async throws {
        guard let id = rule.action?.applicationBundleID, let path = rule.action?.applicationPath else {
            throw FrogError.message("Choose an application for this rule.")
        }
        let url = resolve(id) ?? URL(fileURLWithPath: path)
        guard bundleIdentifier(url) == id else { throw FrogError.message("Choose the application again; it has moved or been replaced.") }
        try await open(url)
    }
}

private actor ApplicationForeground {
    static let shared = ApplicationForeground()
    func request(pid: pid_t) -> Bool {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        return AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
    }
}
