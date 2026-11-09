import AppKit
import ApplicationServices
import Carbon
import FrogCore

/// Injectable AX boundary for native editor fixtures without test-runner permissions.
@MainActor
struct ClipboardHistoryTargetAccess {
    var trusted: () -> Bool
    var frontmostPID: () -> pid_t?
    var ownPID: pid_t
    var window: () -> AXUIElement?
    var focused: () -> AXUIElement?
    var range: (AXUIElement) -> CFRange?
    var role: (AXUIElement) -> String?
    var secure: (AXUIElement) -> Bool
    var enabled: (AXUIElement) -> Bool
    var editable: (AXUIElement) -> Bool
    var nativePasteAvailable: () -> Bool = { false }
    var keyboardFocused: (AXUIElement) -> Bool = { _ in true }
    /// Brings the original app forward again, which hands keyboard focus back to its window.
    var activate: () -> Void = {}
    var restoreFocus: (AXUIElement) -> Void = { _ in }
    var pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    /// Whether the app keeps its text fields from Accessibility, as Chrome, Helium and Electron apps do
    /// unless a screen reader switched them on, which Frog never does.
    var hidesFields: () -> Bool = { false }
    /// Secure keyboard entry is on, as it is while a password field has focus.
    var secureInput: () -> Bool = { false }
    var command: () throws -> Void

    static func live(application: AXUIElement, pid: pid_t,
                     element: @escaping (AXUIElement, String) -> AXUIElement? = { AXRead.element($0, $1) },
                     limit: @escaping (AXUIElement, Float) -> Void = { _ = AXUIElementSetMessagingTimeout($0, $1) },
                     focus: @escaping (AXUIElement) -> Void = {
                         AXUIElementSetAttributeValue($0, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                     }) -> Self {
        // One search of the app's menus serves every check and the paste itself.
        live(application: application, pid: pid, menu: MenuCommandCache(application: application),
             element: element, limit: limit, focus: focus)
    }

    private static func live(application: AXUIElement, pid: pid_t, menu: MenuCommandCache,
                             element: @escaping (AXUIElement, String) -> AXUIElement?,
                             limit: @escaping (AXUIElement, Float) -> Void,
                             focus: @escaping (AXUIElement) -> Void) -> Self {
        // A time limit belongs to the one element it is set on. The window and the field an
        // application hands out do not inherit the application's, and without their own every
        // question about them waits for a stalled app as long as the system allows.
        let handedOut: (String) -> AXUIElement? = { attribute in
            let found = element(application, attribute)
            if let found { limit(found, 0.15) }
            return found
        }
        return Self(trusted: { SelectionService.isTrusted },
             frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
             ownPID: ProcessInfo.processInfo.processIdentifier,
             window: { handedOut(kAXFocusedWindowAttribute) },
             focused: { handedOut(kAXFocusedUIElementAttribute) },
             range: { AXRead.range($0) }, role: { AXRead.string($0, kAXRoleAttribute) },
             secure: { AXRead.string($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole },
             enabled: { AXRead.boolean($0, kAXEnabledAttribute) != false },
             editable: { AXRead.isEditable($0) },
             nativePasteAvailable: { menu.item("v") != nil },
             keyboardFocused: { AXRead.boolean($0, kAXFocusedAttribute) != false },
             // Only called while the original app/window still owns focus. The app can
             // still be frontmost while a closing nonactivating panel owns keyboard focus.
             activate: { NSRunningApplication(processIdentifier: pid)?.activate(options: []) },
             restoreFocus: { focused in
                 // The limit is for questions. A request that is cut short may still be
                 // carried out, so handing focus back keeps the time it always had.
                 limit(focused, 0)
                 focus(focused)
                 limit(focused, 0.15)
             },
             hidesFields: {
                 guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
                 return SelectionWatcher.System.live.builtOnChromium(url)
             },
             secureInput: { IsSecureEventInputEnabled() },
             command: { try ClipboardSelection.command("v", keyCode: 9, menu: menu, pid: pid) })
    }
}

/// The panel never activates Frog; insertion requires the original app/window/field.
@MainActor
struct NativeClipboardHistoryPasteTarget: ClipboardHistoryPasteTarget {
    let window: AXUIElement
    let focused: AXUIElement
    let range: CFRange?
    let pid: pid_t
    let access: ClipboardHistoryTargetAccess
    var applicationPID: pid_t? { pid }

    /// The field when Accessibility shows it, otherwise the app in front when it hides its fields.
    static func captureAny() -> (any ClipboardHistoryPasteTarget)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        let access = ClipboardHistoryTargetAccess.live(application: application, pid: pid)
        return capture(pid: pid, access: access) ?? ApplicationClipboardHistoryPasteTarget.capture(pid: pid, access: access)
    }

    static func capture(pid: pid_t, access: ClipboardHistoryTargetAccess) -> Self? {
        guard access.trusted(), pid != access.ownPID,
              let window = access.window(), let focused = access.focused(),
              !access.secure(focused), access.enabled(focused) else { return nil }
        // Electron/IDE text inputs can support native Paste without exposing
        // AXSelectedTextRange. A concrete editable identity is still required;
        // an app-wide Paste menu alone cannot identify the intended field.
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(access.role(focused) ?? "") || access.editable(focused) else { return nil }
        let range = access.range(focused)
        if let range, range.location < 0 || range.length < 0 { return nil }
        // A text field with neither a range nor an editable value is taken on trust here.
        // Whether its app offers a Paste command is found by reading the whole menu bar,
        // so that waits until an item is chosen: validateField asks before anything is pasted.
        guard access.frontmostPID() == pid else { return nil }
        return Self(window: window, focused: focused, range: range, pid: pid, access: access)
    }

    /// About half a second for the original field to have keyboard focus again.
    static let focusAttempts = 25
    /// Attempts the field gets to take focus back by itself before it is asked to.
    static let focusGrace = 3

    func prepareForPaste(isCurrent: () -> Bool) async throws {
        // Closing a key nonactivating panel releases focus asynchronously. Wait
        // only for missing focus, never for a different app/window/field to leave.
        var activated = false, refocused = false
        for attempt in 0..<Self.focusAttempts {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            guard access.trusted(), access.frontmostPID() == pid else { throw changedTarget() }
            if let currentWindow = access.window() {
                guard CFEqual(window, currentWindow) else { throw changedTarget() }
                let current = access.focused()
                if let current { guard CFEqual(focused, current) else { throw changedTarget() } }
                try validateField(current ?? focused)
                if activated, let current, access.keyboardFocused(current) { return }
                if !activated { access.activate(); activated = true }
                // Focus comes back by itself once the app is in front. A single-line field asked
                // to take focus it already has starts editing over and selects all of its text,
                // so it is asked only when focus stays away.
                else if !refocused, attempt >= Self.focusGrace { access.restoreFocus(focused); refocused = true }
            }
            if attempt < Self.focusAttempts - 1 { try await access.pause() }
        }
        throw FrogError.message("The original field did not regain focus. The item is copied; paste it manually.")
    }

    func paste() throws {
        guard access.trusted(), access.frontmostPID() == pid,
              let currentWindow = access.window(), CFEqual(window, currentWindow) else {
            throw FrogError.message("The target app changed. The item is copied; paste it where you want it.")
        }
        guard let current = access.focused(), CFEqual(focused, current), !access.secure(current) else {
            throw FrogError.message("The target field changed. The item is copied; paste it where you want it.")
        }
        guard access.keyboardFocused(current) else {
            throw FrogError.message("The original field lost keyboard focus. The item is copied; paste it manually.")
        }
        try validateField(current)
        try access.command()
    }

    private func validateField(_ current: AXUIElement) throws {
        guard !access.secure(current) else { throw changedTarget() }
        if let range {
            guard let currentRange = access.range(focused), currentRange.location == range.location, currentRange.length == range.length else {
                throw FrogError.message("The insertion point changed. The item is copied; paste it where you want it.")
            }
        }
        guard access.enabled(current) else {
            throw FrogError.message("The target field is disabled. The item is copied; paste it manually.")
        }
        guard range != nil || access.editable(current) || access.nativePasteAvailable() else {
            throw FrogError.message("The original field does not accept Paste. The item is copied; paste it manually.")
        }
    }

    private func changedTarget() -> FrogError {
        .message("The target app or field changed. The item is copied; paste it where you want it.")
    }
}

/// The app in front, for apps that hide their fields from Accessibility: Chrome, Helium, Arc and
/// Electron apps such as Slack or Claude. Frog cannot see which field has focus there, so it pastes
/// with the app's own Paste command into its focused window, as other clipboard managers do. An app
/// that shows its fields gets the field instead, and a password field is never pasted into.
@MainActor
struct ApplicationClipboardHistoryPasteTarget: ClipboardHistoryPasteTarget {
    let window: AXUIElement
    let pid: pid_t
    let access: ClipboardHistoryTargetAccess
    var applicationPID: pid_t? { pid }

    /// About 60 ms after the app is brought forward again, for keyboard focus to leave the closed panel.
    static let settlePauses = 3

    static func capture(pid: pid_t, access: ClipboardHistoryTargetAccess) -> Self? {
        guard access.trusted(), pid != access.ownPID, access.frontmostPID() == pid,
              !access.secureInput(), let window = access.window() else { return nil }
        if let focused = access.focused() {
            // A field Accessibility does show was already judged by the precise target.
            guard !access.secure(focused), access.hidesFields() else { return nil }
        }
        return Self(window: window, pid: pid, access: access)
    }

    func prepareForPaste(isCurrent: () -> Bool) async throws {
        try check(isCurrent)
        access.activate()
        for _ in 0..<Self.settlePauses {
            try await access.pause()
            try check(isCurrent)
        }
    }

    func paste() throws {
        try check({ true })
        guard !access.secureInput() else {
            throw FrogError.message("A password field has focus. The item is copied; paste it manually.")
        }
        try access.command()
    }

    private func check(_ isCurrent: () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard access.trusted(), access.frontmostPID() == pid else { throw changedTarget() }
        if let current = access.window() { guard CFEqual(window, current) else { throw changedTarget() } }
    }

    private func changedTarget() -> FrogError {
        .message("The target app or window changed. The item is copied; paste it where you want it.")
    }
}
