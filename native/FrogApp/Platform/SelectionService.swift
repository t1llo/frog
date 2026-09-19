import AppKit
import ApplicationServices
import FrogCore

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

    func capture() async throws -> TextSelection {
        guard Self.isTrusted else {
            throw FrogError.message("Allow Frog in System Settings → Privacy & Security → Accessibility, then try again.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw FrogError.message("Select text in another application before using a rule.")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = AXRead.element(application, kAXFocusedUIElementAttribute),
              let range = AXRead.range(element), range.location >= 0, range.length > 0 else {
            throw FrogError.message("This application does not expose a reliable text selection. Copy the text into Frog’s Try text view.")
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
final class TextSelection {
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
    private var observesChanges = false

    fileprivate init(text: String, element: AXUIElement, application: AXUIElement,
                     pid: pid_t, range: CFRange, value: String?) {
        self.text = text
        self.element = element
        self.application = application
        self.pid = pid
        self.range = range
        self.value = value
        window = AXRead.element(application, kAXFocusedWindowAttribute)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            // The observer source is installed only on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<TextSelection>.fromOpaque(context).takeUnretainedValue().invalidated = true
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
            observesChanges = requests.map {
                AXObserverAddNotification(created, $0.0, $0.1 as CFString, context) == .success
            }.allSatisfy { $0 }
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
        guard !invalidated, !consumed, SelectionService.isTrusted,
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
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            // Never replace the whole AXValue: doing so destroys rich document formatting.
            consumed = true
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            guard result == .success else {
                // A failed AX call may have partially applied. Do not retry with paste.
                throw FrogError.message("The application could not replace the selection (Accessibility error \(result.rawValue)). The result is on the clipboard.")
            }
            return
        }
        // Paste is only permitted for an observable, fully snapshotted editable control.
        let role = AXRead.string(element, kAXRoleAttribute)
        var valueSettable = DarwinBoolean(false)
        guard observesChanges, value != nil, window != nil,
              role == kAXTextAreaRole || role == kAXTextFieldRole,
              AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success,
              valueSettable.boolValue,
              AXRead.boolean(element, kAXEnabledAttribute) == true,
              AXRead.boolean(element, kAXFocusedAttribute) == true,
              CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false), isValid else {
            throw FrogError.message("This application cannot safely replace the selection automatically. The result is on the clipboard.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        consumed = true
        // Target the captured process, not whichever application receives a global event.
        // No await/run-loop turn occurs between final validation and posting the pair.
        down.postToPid(pid)
        up.postToPid(pid)
    }
}

private enum AXRead {
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
