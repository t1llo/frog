import AppKit
import ApplicationServices
import FrogCore

@MainActor
protocol CapturedTextSelection: AnyObject {
    var text: String { get }
    /// Where the selection is, in Cocoa screen coordinates.
    var anchor: CGRect? { get }
    /// The sentence or paragraph around the selection, at most 1,000 characters.
    var context: String? { get }
    var applicationName: String? { get }
    /// The document or page address. Kept in History and notes, never sent to a model.
    var source: String? { get }
    func replace(with text: String) async throws
}

/// Captures that cannot tell where the selection is or what surrounds it, like the compatibility
/// Copy, provide none of it. These are protocol requirements so that a capture seen as
/// `any CapturedTextSelection` still answers with its own values.
extension CapturedTextSelection {
    var anchor: CGRect? { nil }
    var context: String? { nil }
    var applicationName: String? { nil }
    var source: String? { nil }
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

    /// The app whose selection an answer rule reads: the frontmost one, once the shortcut keys are released.
    static func answerTarget() async throws -> pid_t {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw FrogError.message("Select text in another application before using a rule.")
        }
        try await ClipboardSelection.waitForShortcutRelease(
            message: "Release the shortcut keys before Frog reads the selection, then try again.")
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw FrogError.message("The selected app changed before reading the selection. Try again.")
        }
        return app.processIdentifier
    }

    func capture() async throws -> any CapturedTextSelection {
        guard Self.isTrusted else {
            throw FrogError.message("Allow Frog in System Settings → Privacy & Security → Accessibility, then try again.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw FrogError.message("Select text in another application before using a rule.")
        }
        // Carbon's key-release event can arrive while Command/Option/Control is
        // still physically held. Wait before either AX capture or Copy/Paste.
        let released = try await ClipboardSelection.waitForShortcutRelease()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw FrogError.message("The selected app changed before reading the selection. Try again.")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Every read below waits for the other app on the main thread. A timeout
        // covers only the element it is set on, so each derived element gets its own.
        AXUIElementSetMessagingTimeout(application, AXRead.selectionTimeout)
        let element = AXRead.element(application, kAXFocusedUIElementAttribute, timeout: AXRead.selectionTimeout)
        if let element, AXRead.string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
            throw FrogError.message("Frog does not read password fields.")
        }
        if let element, let range = AXRead.range(element), range.length == 0,
           [kAXTextAreaRole, kAXTextFieldRole].contains(AXRead.string(element, kAXRoleAttribute) ?? "") {
            throw FrogError.message("Select some text before pressing the shortcut.")
        }
        guard let element, let range = AXRead.range(element), range.location >= 0, range.length > 0 else {
            return try await ClipboardSelection.capture(application: application, pid: app.processIdentifier, released: released)
        }
        let value = AXRead.string(element, kAXValueAttribute)
        let selected = AXRead.string(element, kAXSelectedTextAttribute)
        let substring = value.flatMap { AXRead.substring($0, range: range) }
        guard let text = selected ?? substring, !text.isEmpty,
               value == nil || substring == text else {
            return try await ClipboardSelection.capture(application: application, pid: app.processIdentifier, released: released)
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
        window = AXRead.element(application, kAXFocusedWindowAttribute, timeout: AXRead.selectionTimeout)
        if let window {
            pasteTarget = ClipboardSelection(text: text, application: application, window: window, focused: element, pid: pid)
        }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            // The observer source is installed only on the main run loop.
            MainActor.assumeIsolated {
                let selection = Unmanaged<TextSelection>.fromOpaque(context).takeUnretainedValue()
                // Nothing reads the answer once the selection is invalid or handed to
                // Paste, and Paste itself sends a burst of these notifications.
                guard !selection.invalidated, !selection.consumed else { return }
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

    // Answers read these right after capture. Writing never does, so it makes none of these reads.
    private(set) lazy var anchor: CGRect? = self.readAnchor()
    private(set) lazy var context: String? = self.readContext()
    private(set) lazy var applicationName: String? = NSRunningApplication(processIdentifier: self.pid)?.localizedName
    private(set) lazy var source: String? = self.readSource()

    /// The most text read to find the context, in UTF-16 units.
    private static let contextReadLimit = 200_000

    private func readAnchor() -> CGRect? {
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = screens.first?.height ?? 0
        func rect(_ range: CFRange) -> CGRect? {
            AXRead.bounds(element, range: range).flatMap {
                AXGeometry.cocoaRect($0, primaryHeight: primaryHeight, screens: screens)
            }
        }
        let union = rect(range)
        // The screen that shows most of the selection.
        let screen = union.flatMap { union in
            screens.max { lhs, rhs in
                let a = lhs.intersection(union), b = rhs.intersection(union)
                return a.width * a.height < b.width * b.height
            }
        }
        return SelectionAnchor.choose(union: union,
                                      last: rect(CFRange(location: range.location + range.length - 1, length: 1)),
                                      screenHeight: screen?.height ?? primaryHeight)
    }

    private func readContext() -> String? {
        let span: (location: Int, length: Int)
        let windowText: String
        if let value, (value as NSString).length <= Self.contextReadLimit {
            span = (0, (value as NSString).length)
            windowText = value
        } else {
            guard let count = AXRead.numberOfCharacters(element) else { return nil }
            span = ContextWindow.range(selection: (range.location, range.length), count: count, margin: 1_500)
            guard span.length > 0, span.length <= Self.contextReadLimit,
                  let text = AXRead.string(element, range: CFRange(location: span.location, length: span.length))
            else { return nil }
            windowText = text
        }
        guard range.location >= span.location else { return nil }
        return SurroundingText.around(selection: NSRange(location: range.location - span.location, length: range.length),
                                      in: windowText)
    }

    private func readSource() -> String? {
        if let window, let document = AXRead.url(window, kAXDocumentAttribute),
           let address = SourceAddress.clean(document) {
            return address
        }
        // A browser exposes the page address on the web area that holds the selection.
        var current: AXUIElement? = element
        for _ in 0...8 {
            guard let candidate = current else { return nil }
            if AXRead.string(candidate, kAXRoleAttribute) == "AXWebArea" {
                return AXRead.url(candidate, "AXURL").flatMap(SourceAddress.clean)
            }
            current = AXRead.element(candidate, kAXParentAttribute, timeout: AXRead.selectionTimeout)
        }
        return nil
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
        // Taken before the result goes onto the clipboard, so the paste below can put it back.
        let original = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw FrogError.message("The result could not be copied to the clipboard.")
        }
        guard isValid else {
            throw FrogError.message("The original selection changed or lost focus. The result is on the clipboard; paste it where you want it.")
        }
        if let pasteTarget {
            // Chromium can report AXSelectedText writes as successful without editing.
            // Use its ordinary Copy/Paste path, with a fresh comparison before paste.
            consumed = true
            try await pasteTarget.replace(with: text, restoring: original)
            return
        }
        throw FrogError.message("The app does not expose its active window. The result is on the clipboard.")
    }
}

enum AXRead {
    /// Longest wait for one answer from the app that holds the selection. Without a
    /// bound, an app that stopped answering holds Frog for the much longer system
    /// default on every call; a shorter one would fail reads of a long document.
    static let selectionTimeout: Float = 1

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
    /// Reads an element and bounds the calls later made on it.
    static func element(_ element: AXUIElement, _ name: String, timeout: Float) -> AXUIElement? {
        guard let result = self.element(element, name) else { return nil }
        AXUIElementSetMessagingTimeout(result, timeout)
        return result
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

    private static func attribute(_ element: AXUIElement, _ name: String, range: CFRange) -> CFTypeRef? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success else { return nil }
        return result
    }
    /// The rectangle of a text range, in Accessibility coordinates (origin top left of the primary display).
    static func bounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
        guard let raw = attribute(element, kAXBoundsForRangeParameterizedAttribute, range: range),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }
    /// Only the given part of an element's text, so a long document is never read whole.
    static func string(_ element: AXUIElement, range: CFRange) -> String? {
        attribute(element, kAXStringForRangeParameterizedAttribute, range: range) as? String
    }
    static func numberOfCharacters(_ element: AXUIElement) -> Int? {
        (attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    }
    static func url(_ element: AXUIElement, _ name: String) -> URL? {
        guard let raw = attribute(element, name) else { return nil }
        if CFGetTypeID(raw) == CFURLGetTypeID() { return (raw as! CFURL) as URL }
        return (raw as? String).flatMap { URL(string: $0) }
    }

    static func isEditable(_ element: AXUIElement) -> Bool {
        guard let role = AXRead.string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXWebArea"].contains(role),
              AXRead.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              AXRead.boolean(element, kAXEnabledAttribute) != false else { return false }
        var settable = DarwinBoolean(false)
        return AXRead.boolean(element, "AXEditable") == true ||
            (AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue)
    }
}
