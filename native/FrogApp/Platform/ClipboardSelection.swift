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
    private let menu: MenuCommandCache
    private let input: [UInt32]
    private var consumed = false
    private var invalidated = false
    private var workspaceObserver: NSObjectProtocol?

    init(text: String, application: AXUIElement, window: AXUIElement, focused: AXUIElement?, pid: pid_t,
         menu: MenuCommandCache? = nil) {
        self.text = text; self.application = application; self.window = window; self.focused = focused; self.pid = pid
        self.menu = menu ?? MenuCommandCache(application: application)
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
        guard let window = AXRead.element(application, kAXFocusedWindowAttribute, timeout: AXRead.selectionTimeout) else {
            throw FrogError.message("The app does not expose its active window. Copy your selection into Try text.")
        }
        let focused = AXRead.element(application, kAXFocusedUIElementAttribute, timeout: AXRead.selectionTimeout)
        try await waitForShortcutRelease()
        guard modifiersReleased, sameTarget(application, window: window, focused: focused, pid: pid) else {
            throw FrogError.message("Release the shortcut keys and keep the selected app focused, then try again.")
        }
        let menu = MenuCommandCache(application: application)
        var sent: [UInt32]?
        let text = try await FreshSelectionCopy.read(pasteboard: .general, lateCopy: { _ in
            // The selected text is unknown here. A clipboard change passes for the late
            // answer only while nothing was typed or clicked since and the app is still in front.
            sent == inputSnapshot() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }) {
            guard sameTarget(application, window: window, focused: focused, pid: pid) else {
                throw FrogError.message("The selected app changed before copying.")
            }
            try command("c", keyCode: 8, menu: menu, pid: pid)
            sent = inputSnapshot()
        }
        guard sameTarget(application, window: window, focused: focused, pid: pid) else {
            throw FrogError.message("The selected app changed while copying.")
        }
        return ClipboardSelection(text: text, application: application, window: window, focused: focused, pid: pid, menu: menu)
    }

    func replace(with result: String) async throws {
        // Set before validation. FreshSelectionCopy restores this result on failure,
        // also when the app answers Copy late; do not clear the pasteboard again
        // while Paste is consuming it.
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(result, forType: .string) else { throw FrogError.message("Could not copy the result.") }
        guard !consumed, !invalidated, Self.inputSnapshot() == input, Self.modifiersReleased,
              Self.sameTarget(application, window: window, focused: focused, pid: pid) else {
            throw FrogError.message("The selection changed or you interacted with the app. The result is copied; paste it where you want it.")
        }
        guard canPaste else {
            throw FrogError.message("The app did not expose an editable target. The result is copied; paste it into your text field.")
        }
        consumed = true
        // Re-copy immediately before paste: window identity alone cannot establish selection identity.
        let beforeCopy = Self.inputSnapshot()
        let current = try await FreshSelectionCopy.read(pasteboard: .general, lateCopy: { [text] in $0 == text }) {
            try Self.command("c", keyCode: 8, menu: self.menu, pid: self.pid)
        }
        let afterCopy = Self.inputSnapshot()
        guard !invalidated, current == text, afterCopy.dropFirst() == beforeCopy.dropFirst(),
              afterCopy[0] &- beforeCopy[0] <= 1, Self.modifiersReleased,
              Self.sameTarget(application, window: window, focused: focused, pid: pid) else {
            throw FrogError.message("The original selection changed. The result is on the clipboard.")
        }
        guard canPaste else { throw FrogError.message("The field is no longer editable. The result is on the clipboard.") }
        try Task.checkCancellation()
        try Self.putBack(result, on: .general)
        try Self.command("v", keyCode: 9, menu: menu, pid: pid)
    }

    private static var modifiersReleased: Bool {
        // Inspect physical keys, not flags left on synthetic Copy/Paste events.
        ![54, 55, 56, 60, 58, 61, 59, 62].contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
    }

    static func waitForShortcutRelease(message: String = "Release the shortcut keys before Frog copies the selection, then try again.") async throws {
        for _ in 0..<80 {
            try Task.checkCancellation()
            if modifiersReleased { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw FrogError.message(message)
    }

    private var canPaste: Bool {
        if let focused, Self.isEditable(focused) { return true }
        // Electron/Chromium may omit the focused AX field entirely. An enabled
        // native Paste command is another app-provided signal of editability.
        return menu.item("v") != nil
    }

    static func command(_ character: String, keyCode: CGKeyCode, menu: MenuCommandCache, pid: pid_t) throws {
        if let item = menu.item(character), press(item) { return }
        try key(keyCode, pid: pid)
    }

    /// Paste inserts whatever the clipboard holds at that moment. The Copy that
    /// checked the selection, or another writer, may have replaced the result since.
    static func putBack(_ result: String, on pasteboard: NSPasteboard) throws {
        guard pasteboard.string(forType: .string) != result else { return }
        pasteboard.clearContents()
        guard pasteboard.setString(result, forType: .string) else { throw FrogError.message("Could not copy the result.") }
    }

    private static func press(_ item: AXUIElement) -> Bool {
        // A press that outlasts its timeout reports failure although the app may
        // still carry it out, and the key sent in its place would then repeat the
        // command. The press therefore waits as long as macOS waits by default.
        AXUIElementSetMessagingTimeout(item, 0)
        defer { AXUIElementSetMessagingTimeout(item, MenuCommandSearch.elementTimeout) }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    static func menuCommand(_ character: String, application: AXUIElement) -> AXUIElement? {
        guard let bar = AXRead.element(application, kAXMenuBarAttribute) else { return nil }
        return MenuCommandSearch.find(character: character, modifiers: 0, under: bar, depth: 5, reader: .live)
    }

    /// Whether `element` is the enabled menu item for Command plus `character`.
    static func isMenuCommand(_ element: AXUIElement, _ character: String) -> Bool {
        MenuCommandSearch.matches(element, character: character, modifiers: 0, reader: .live)
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

/// Finds the enabled menu item for a keyboard command below a menu bar or one of its menus.
enum MenuCommandSearch {
    /// Longest wait for one answer while reading a menu. A menu bar holds hundreds of
    /// elements and a timeout covers only the element it is set on.
    static let elementTimeout: Float = 0.15

    /// What the search asks of one menu element. The live reader asks the app that owns the menu.
    struct Reader<Element> {
        /// Called once before an element is read.
        var prepare: (Element) -> Void = { _ in }
        var role: (Element) -> String?
        var character: (Element) -> String?
        var modifiers: (Element) -> Int?
        var enabled: (Element) -> Bool?
        var children: (Element) -> [Element]?
    }

    /// Whether `element` is the enabled menu item for Command plus `character` with
    /// exactly `modifiers` (Shift = 1, Option = 2, Control = 4, no Command = 8).
    static func matches<Element>(_ element: Element, character: String, modifiers: Int, reader: Reader<Element>) -> Bool {
        reader.role(element) == kAXMenuItemRole && reader.character(element)?.lowercased() == character
            && reader.modifiers(element) == modifiers && reader.enabled(element) == true
    }

    /// Reads the menus in the order they are shown, so the menus on the left that hold
    /// the common commands come first, and gives up after `seconds` or 1,000 elements.
    static func find<Element>(character: String, modifiers: Int, under root: Element, depth limit: Int,
                              seconds: TimeInterval = 1.5, reader: Reader<Element>,
                              now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                              isCancelled: () -> Bool = { false }) -> Element? {
        var pending = [(root, 0)]
        var visited = 0
        let deadline = now() + seconds
        while let (element, depth) = pending.popLast(), visited < 1_000, now() < deadline, !isCancelled() {
            visited += 1
            reader.prepare(element)
            if matches(element, character: character, modifiers: modifiers, reader: reader) { return element }
            if depth < limit, let children = reader.children(element) {
                // The stack hands back its last entry first.
                pending.append(contentsOf: children.prefix(1_000 - visited).reversed().map { ($0, depth + 1) })
            }
        }
        return nil
    }
}

extension MenuCommandSearch.Reader where Element == AXUIElement {
    static var live: Self {
        .init(prepare: { AXUIElementSetMessagingTimeout($0, MenuCommandSearch.elementTimeout) },
              role: { AXRead.string($0, kAXRoleAttribute) },
              character: { AXRead.string($0, kAXMenuItemCmdCharAttribute) },
              modifiers: { (AXRead.attribute($0, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue },
              enabled: { AXRead.boolean($0, kAXEnabledAttribute) },
              children: { AXRead.attribute($0, kAXChildrenAttribute) as? [AXUIElement] })
    }
}

/// The Copy and Paste menu items of one captured target. Finding them walks the
/// app's menu bar, so a found item is kept for the checks and commands that follow.
@MainActor
final class MenuCommandCache {
    private let find: (String) -> AXUIElement?
    private let matches: (AXUIElement, String) -> Bool
    private var items: [String: AXUIElement] = [:]

    init(find: @escaping (String) -> AXUIElement?, matches: @escaping (AXUIElement, String) -> Bool) {
        self.find = find; self.matches = matches
    }

    convenience init(application: AXUIElement) {
        self.init(find: { ClipboardSelection.menuCommand($0, application: application) },
                  matches: { ClipboardSelection.isMenuCommand($0, $1) })
    }

    func item(_ character: String) -> AXUIElement? {
        // Apps enable, disable and rebuild menu items as their state changes. A kept
        // item is used only while it still answers as the same enabled command; a
        // missing one is not remembered, because Paste can become available later.
        if let item = items[character], matches(item, character) { return item }
        let item = find(character)
        items[character] = item
        return item
    }
}

@MainActor
enum FreshSelectionCopy {
    /// The wait for an answer to a Copy that `read` gave up on.
    private(set) static var lateCopyWatch: Task<Void, Never>?

    /// `lateCopy` is asked about text that reaches the clipboard after `read` gave up
    /// without seeing any change. Return true only for the answer to this Copy request:
    /// the clipboard is then put back as it was, as it is after an answer in time.
    static func read(pasteboard: NSPasteboard, attempts: Int = 60, lateCopy: ((String) -> Bool)? = nil,
                     copy: () throws -> Void) async throws -> String {
        // An answer that arrives from now on belongs to this request.
        lateCopyWatch?.cancel(); lateCopyWatch = nil
        ClipboardHistoryCaptureGate.shared.begin()
        defer { ClipboardHistoryCaptureGate.shared.end(pasteboard: pasteboard) }
        let original: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let saved = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
            return saved
        } ?? []
        let previousCount = pasteboard.changeCount
        var copiedCount: Int?
        var requested = false
        defer {
            // Do not overwrite a clipboard update that happened after ours.
            if let copiedCount, pasteboard.changeCount == copiedCount {
                pasteboard.clearContents()
                if !original.isEmpty { pasteboard.writeObjects(original) }
            } else if requested, copiedCount == nil, let lateCopy {
                undoLateCopy(on: pasteboard, after: previousCount, restoring: original, when: lateCopy)
            }
        }
        try Task.checkCancellation()
        try copy()
        requested = true
        for _ in 0..<attempts {
            if pasteboard.changeCount != previousCount {
                copiedCount = pasteboard.changeCount
                try Task.checkCancellation()
                // Some apps clear/declare clipboard types before supplying text.
                // A changed count is necessary, but is not yet a completed Copy.
                if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
            // Once Copy is posted, allow its bounded reply even on cancellation so
            // a delayed clipboard write can be restored before returning.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
        }
        try Task.checkCancellation()
        if copiedCount != nil { throw FrogError.message("Copy did not return selected text. Select text in an editable field and try again.") }
        throw FrogError.message("The app did not copy a selection. Select text first, then try the shortcut again.")
    }

    /// A busy app can answer Copy seconds after it was asked. By then nobody waits for
    /// the text, and it would silently replace what the clipboard held.
    private static func undoLateCopy(on pasteboard: NSPasteboard, after count: Int, restoring original: [NSPasteboardItem],
                                     when isLateCopy: @escaping (String) -> Bool) {
        lateCopyWatch = Task { @MainActor in
            // Clipboard history stays open meanwhile: the person may copy something.
            for _ in 0..<250 {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
                // Some apps clear the clipboard first and supply the text a moment later.
                guard pasteboard.changeCount != count, let text = pasteboard.string(forType: .string),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                guard isLateCopy(text) else { return }
                ClipboardHistoryCaptureGate.shared.begin()
                defer { ClipboardHistoryCaptureGate.shared.end(pasteboard: pasteboard) }
                pasteboard.clearContents()
                if !original.isEmpty { pasteboard.writeObjects(original) }
                return
            }
        }
    }
}
