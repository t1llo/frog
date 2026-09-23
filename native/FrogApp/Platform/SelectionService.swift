import AppKit
import ApplicationServices
import FrogCore

@MainActor
protocol CapturedTextSelection: AnyObject {
    var text: String { get }
    func replace(with text: String) async throws
}

@MainActor
final class SelectionService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        // The C SDK exposes this constant as a mutable global; use its documented key.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func capture() async throws -> any CapturedTextSelection {
        guard Self.isTrusted else {
            throw FrogError.message("Allow Frog in System Settings → Privacy & Security → Accessibility, then try again.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw FrogError.message("Select text in another application before using a rule.")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let element = AXRead.element(application, kAXFocusedUIElementAttribute)
        if let element, AXRead.string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
            throw FrogError.message("Frog does not read password fields.")
        }
        if let element, let range = AXRead.range(element), range.length == 0,
           [kAXTextAreaRole, kAXTextFieldRole].contains(AXRead.string(element, kAXRoleAttribute) ?? "") {
            throw FrogError.message("Select some text before pressing the shortcut.")
        }
        guard let element, let range = AXRead.range(element), range.location >= 0, range.length > 0 else {
            return try await ClipboardSelection.capture(application: application, pid: app.processIdentifier)
        }
        let value = AXRead.string(element, kAXValueAttribute)
        let selected = AXRead.string(element, kAXSelectedTextAttribute)
        let substring = value.flatMap { AXRead.substring($0, range: range) }
        guard let text = selected ?? substring, !text.isEmpty,
              value == nil || substring == text else {
            throw FrogError.message("The selected text could not be read reliably. Try selecting it again.")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier else {
            throw FrogError.message("The selected text belongs to an unavailable application.")
        }
        let selection = TextSelection(text: text, element: element, application: application,
                                      pid: pid, range: range, value: value)
        guard selection.isValid else {
            throw FrogError.message("The selection changed while it was being captured. Try again.")
        }
        return selection
    }
}

@MainActor
final class TextSelection: CapturedTextSelection {
    let text: String
    private let element: AXUIElement
    private let application: AXUIElement
    private let pid: pid_t
    private let range: CFRange
    private let value: String?
    private let window: AXUIElement?
    private var observer: AXObserver?
    private var workspaceObserver: NSObjectProtocol?
    private var invalidated = false
    private var consumed = false
    private var pasteTarget: ClipboardSelection?

    fileprivate init(text: String, element: AXUIElement, application: AXUIElement,
                     pid: pid_t, range: CFRange, value: String?) {
        self.text = text
        self.element = element
        self.application = application
        self.pid = pid
        self.range = range
        self.value = value
        window = AXRead.element(application, kAXFocusedWindowAttribute)
        if let window {
            pasteTarget = ClipboardSelection(text: text, application: application, window: window, focused: element, pid: pid)
        }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            // The observer source is installed only on the main run loop.
            MainActor.assumeIsolated {
                let selection = Unmanaged<TextSelection>.fromOpaque(context).takeUnretainedValue()
                // Browsers emit selection/focus notifications even when Copy leaves
                // the snapshot unchanged. Validate the state instead of the notification.
                if !selection.matchesSnapshot { selection.invalidated = true }
            }
        }
        if AXObserverCreate(pid, callback, &created) == .success, let created {
            observer = created
            let context = Unmanaged.passUnretained(self).toOpaque()
            let requests: [(AXUIElement, String)] = [
                (element, kAXSelectedTextChangedNotification),
                (element, kAXValueChangedNotification),
                (application, kAXFocusedUIElementChangedNotification),
                (application, kAXFocusedWindowChangedNotification)
            ]
            for request in requests {
                _ = AXObserverAddNotification(created, request.0, request.1 as CFString, context)
            }
            _ = AXObserverAddNotification(created, element, kAXUIElementDestroyedNotification as CFString, context)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activePID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if activePID != self?.pid { self?.invalidated = true }
            }
        }
    }

    isolated deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    fileprivate var isValid: Bool {
        !invalidated && !consumed && matchesSnapshot
    }

    private var matchesSnapshot: Bool {
        guard SelectionService.isTrusted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = AXRead.element(application, kAXFocusedUIElementAttribute), CFEqual(focused, element),
              let currentRange = AXRead.range(element),
              currentRange.location == range.location, currentRange.length == range.length else { return false }
        if let window {
            guard let currentWindow = AXRead.element(application, kAXFocusedWindowAttribute),
                  CFEqual(window, currentWindow) else { return false }
        }
        var currentPID: pid_t = 0
        guard AXUIElementGetPid(element, &currentPID) == .success, currentPID == pid else { return false }
        if let value, AXRead.string(element, kAXValueAttribute) != value { return false }
        let selected = AXRead.string(element, kAXSelectedTextAttribute)
            ?? AXRead.string(element, kAXValueAttribute).flatMap { AXRead.substring($0, range: range) }
        return selected == text
    }

    func replace(with text: String) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw FrogError.message("The result could not be copied to the clipboard.")
        }
        guard isValid else {
            throw FrogError.message("The original selection changed or lost focus. The result is on the clipboard; paste it where you want it.")
        }
        let role = AXRead.string(element, kAXRoleAttribute)
        if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role ?? "") {
            // Chromium can report AXSelectedText writes as successful without editing.
            // Use its ordinary Copy/Paste path, with a fresh comparison before paste.
            guard let pasteTarget else {
                throw FrogError.message("The app does not expose its active window. The result is on the clipboard.")
            }
            consumed = true
            try await pasteTarget.replace(with: text)
            return
        }
        throw FrogError.message("This selection is not in a supported editable field. The result is on the clipboard.")
    }
}

enum AXRead {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    static func boolean(_ element: AXUIElement, _ name: String) -> Bool? { attribute(element, name) as? Bool }
    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = attribute(element, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    static func range(_ element: AXUIElement) -> CFRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }
    static func substring(_ value: String, range: CFRange) -> String? {
        let string = value as NSString
        guard range.location >= 0, range.length >= 0, range.location <= string.length,
              range.length <= string.length - range.location else { return nil }
        return string.substring(with: NSRange(location: range.location, length: range.length))
    }
}
