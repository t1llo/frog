import AppKit
import ApplicationServices
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
    var restoreFocus: (AXUIElement) -> Void = { _ in }
    var pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    var command: () throws -> Void

    static func live(application: AXUIElement, pid: pid_t) -> Self {
        Self(trusted: { SelectionService.isTrusted },
             frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
             ownPID: ProcessInfo.processInfo.processIdentifier,
             window: { AXRead.element(application, kAXFocusedWindowAttribute) },
             focused: { AXRead.element(application, kAXFocusedUIElementAttribute) },
             range: { AXRead.range($0) }, role: { AXRead.string($0, kAXRoleAttribute) },
             secure: { AXRead.string($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole },
             enabled: { AXRead.boolean($0, kAXEnabledAttribute) != false },
             editable: { ClipboardSelection.isEditable($0) },
             nativePasteAvailable: { ClipboardSelection.menuCommand("v", application: application) != nil },
             keyboardFocused: { AXRead.boolean($0, kAXFocusedAttribute) != false },
             restoreFocus: { focused in
                 // Only called while the original app/window still owns focus.
                 // The app can still be frontmost while a closing nonactivating
                 // panel owns keyboard focus. Activate only that same app.
                 NSRunningApplication(processIdentifier: pid)?.activate(options: [])
                 AXUIElementSetAttributeValue(focused, kAXFocusedAttribute as CFString, kCFBooleanTrue)
             },
             command: { try ClipboardSelection.command("v", keyCode: 9, application: application, pid: pid) })
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

    static func capture() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        return capture(pid: app.processIdentifier, access: .live(application: application, pid: app.processIdentifier))
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
        if range == nil, !access.editable(focused), !access.nativePasteAvailable() { return nil }
        guard access.frontmostPID() == pid else { return nil }
        return Self(window: window, focused: focused, range: range, pid: pid, access: access)
    }

    func prepareForPaste(isCurrent: () -> Bool) async throws {
        // Closing a key nonactivating panel releases focus asynchronously. Wait
        // only for missing focus, never for a different app/window/field to leave.
        var restored = false
        for attempt in 0..<16 {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            guard access.trusted(), access.frontmostPID() == pid else { throw changedTarget() }
            if let currentWindow = access.window() {
                guard CFEqual(window, currentWindow) else { throw changedTarget() }
                if let current = access.focused() {
                    guard CFEqual(focused, current) else { throw changedTarget() }
                    try validateField(current)
                    if restored && access.keyboardFocused(current) { return }
                } else { try validateField(focused) }
                if !restored { access.restoreFocus(focused); restored = true }
            }
            if attempt < 15 { try await access.pause() }
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
            throw FrogError.message("The original field no longer accepts Paste. The item is copied; paste it manually.")
        }
    }

    private func changedTarget() -> FrogError {
        .message("The target app or field changed. The item is copied; paste it where you want it.")
    }
}
