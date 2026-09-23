import AppKit
import ApplicationServices
import FrogCore

/// Compatibility path for apps that expose Copy but not an AX text range.
/// Clipboard text is accepted only after a fresh change produced by this Copy request.
@MainActor
final class ClipboardSelection: CapturedTextSelection {
    let text: String
    private let application: AXUIElement
    private let window: AXUIElement
    private let focused: AXUIElement?
    private let pid: pid_t
    private let input: [UInt32]
    private var consumed = false
    private var invalidated = false
    private var workspaceObserver: NSObjectProtocol?

    init(text: String, application: AXUIElement, window: AXUIElement, focused: AXUIElement?, pid: pid_t) {
        self.text = text; self.application = application; self.window = window; self.focused = focused; self.pid = pid
        input = Self.inputSnapshot()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activePID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if activePID != self?.pid { self?.invalidated = true } }
        }
    }

    isolated deinit {
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    static func capture(application: AXUIElement, pid: pid_t) async throws -> ClipboardSelection {
        guard let window = AXRead.element(application, kAXFocusedWindowAttribute) else {
            throw FrogError.message("The app does not expose its active window. Copy your selection into Try text.")
        }
        let focused = AXRead.element(application, kAXFocusedUIElementAttribute)
        // A hotkey's modifiers must be released before synthesizing Command-C.
        for _ in 0..<40 {
            if modifiersReleased { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard modifiersReleased, sameTarget(application, window: window, focused: focused, pid: pid) else {
            throw FrogError.message("Release the shortcut keys and keep the selected app focused, then try again.")
        }
        let text = try await FreshSelectionCopy.read(pasteboard: .general) {
            guard sameTarget(application, window: window, focused: focused, pid: pid) else {
                throw FrogError.message("The selected app changed before copying.")
            }
            try key(8, pid: pid)
        }
        guard sameTarget(application, window: window, focused: focused, pid: pid) else {
            throw FrogError.message("The selected app changed while copying.")
        }
        return ClipboardSelection(text: text, application: application, window: window, focused: focused, pid: pid)
    }

    func replace(with result: String) async throws {
        // Every failure still leaves the finished result ready for manual paste.
        defer { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) }
        guard !consumed, !invalidated, Self.inputSnapshot() == input, Self.modifiersReleased,
              Self.sameTarget(application, window: window, focused: focused, pid: pid) else {
            throw FrogError.message("The selection changed or you interacted with the app. The result is copied; paste it where you want it.")
        }
        guard let focused, Self.isEditable(focused) else {
            throw FrogError.message("The app did not expose an editable target. The result is copied; paste it into your text field.")
        }
        consumed = true
        // Re-copy immediately before paste: window identity alone cannot establish selection identity.
        let beforeCopy = Self.inputSnapshot()
        let current = try await FreshSelectionCopy.read(pasteboard: .general) { try Self.key(8, pid: self.pid) }
        let afterCopy = Self.inputSnapshot()
        guard !invalidated, current == text, afterCopy.dropFirst() == beforeCopy.dropFirst(),
              afterCopy[0] &- beforeCopy[0] <= 1, Self.modifiersReleased,
              Self.sameTarget(application, window: window, focused: focused, pid: pid) else {
            throw FrogError.message("The original selection changed. The result is on the clipboard.")
        }
        guard Self.isEditable(focused) else { throw FrogError.message("The field is no longer editable. The result is on the clipboard.") }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(result, forType: .string) else { throw FrogError.message("Could not copy the result.") }
        try Self.key(9, pid: pid)
    }

    private static var modifiersReleased: Bool {
        CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        guard let role = AXRead.string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXWebArea"].contains(role),
              AXRead.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              AXRead.boolean(element, kAXEnabledAttribute) != false else { return false }
        var settable = DarwinBoolean(false)
        return AXRead.boolean(element, "AXEditable") == true ||
            (AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue)
    }

    private static func inputSnapshot() -> [UInt32] {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel]
            .map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0) }
    }

    private static func sameTarget(_ application: AXUIElement, window: AXUIElement, focused: AXUIElement?, pid: pid_t) -> Bool {
        guard SelectionService.isTrusted, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let currentWindow = AXRead.element(application, kAXFocusedWindowAttribute), CFEqual(window, currentWindow) else { return false }
        if let focused {
            guard let current = AXRead.element(application, kAXFocusedUIElementAttribute), CFEqual(focused, current) else { return false }
        }
        return true
    }

    private static func key(_ code: CGKeyCode, pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw FrogError.message("Could not send the selection shortcut.")
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
    }
}

@MainActor
enum FreshSelectionCopy {
    static func read(pasteboard: NSPasteboard, attempts: Int = 30, copy: () throws -> Void) async throws -> String {
        let original: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let saved = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
            return saved
        } ?? []
        let previousCount = pasteboard.changeCount
        var copiedCount: Int?
        defer {
            // Do not overwrite a clipboard update that happened after ours.
            if let copiedCount, pasteboard.changeCount == copiedCount {
                pasteboard.clearContents()
                if !original.isEmpty { pasteboard.writeObjects(original) }
            }
        }
        try Task.checkCancellation()
        try copy()
        for _ in 0..<attempts {
            if pasteboard.changeCount != previousCount {
                copiedCount = pasteboard.changeCount
                try Task.checkCancellation()
                guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FrogError.message("Copy did not return selected text. Select text in an editable field and try again.")
                }
                return text
            }
            // Once Copy is posted, allow its bounded reply even on cancellation so
            // a delayed clipboard write can be restored before returning.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
        }
        try Task.checkCancellation()
        throw FrogError.message("The app did not copy a selection. Select text first, then try the shortcut again.")
    }
}
