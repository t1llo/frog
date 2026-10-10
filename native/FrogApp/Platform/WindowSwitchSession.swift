import Foundation
import Carbon
import CoreGraphics
import FrogCore

/// Frozen ordering while the switcher is open prevents cycling targets from moving.
struct WindowSwitchSession<ID: Hashable> {
    private(set) var windows: [ID] = []
    private(set) var selected: ID?

    mutating func begin(windows: [ID], current: ID?, backwards: Bool) {
        var seen = Set<ID>()
        self.windows = windows.filter { seen.insert($0).inserted }
        selected = current.flatMap { self.windows.contains($0) ? $0 : nil }
        step(backwards: backwards)
    }

    mutating func step(backwards: Bool) {
        guard !windows.isEmpty else { selected = nil; return }
        if let selected, let index = windows.firstIndex(of: selected) {
            self.selected = windows[(index + (backwards ? windows.count - 1 : 1)) % windows.count]
        } else { selected = backwards ? windows.last : windows.first }
    }

    mutating func select(_ id: ID) { if windows.contains(id) { selected = id } }
    mutating func reconcile(windows available: [ID]) {
        let live = Set(available)
        let previous = Set(windows)
        windows = windows.filter { live.contains($0) } + available.filter { !previous.contains($0) }
        if selected.map({ !live.contains($0) }) ?? true { selected = windows.first }
    }
    mutating func reset() { windows = []; selected = nil }
}

/// Pure key routing: only the switcher's keys are consumed, never ordinary typing.
struct WindowSwitchKeyRouter: Sendable {
    static let defaultHotkey = Hotkey(keyCode: 48, modifiers: UInt32(cmdKey))
    private static let baseFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
    private let hotkey: Hotkey
    private let requiredFlags: CGEventFlags

    init(hotkey: Hotkey = Self.defaultHotkey) {
        self.hotkey = hotkey
        var flags: CGEventFlags = []
        if hotkey.modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if hotkey.modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if hotkey.modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        requiredFlags = flags
    }

    func acceptsSearch(flags: CGEventFlags) -> Bool { active && matchesBaseModifiers(flags) }

    private func matchesBaseModifiers(_ flags: CGEventFlags) -> Bool {
        !requiredFlags.isEmpty && flags.intersection(Self.baseFlags) == requiredFlags
    }

    enum Action: Equatable, Sendable { case begin(backwards: Bool), step(backwards: Bool), commit, cancel, search(String), deleteSearch }
    struct Result: Sendable {
        var consume = false
        var action: Action?
        var sessionID: UInt64?
        // Suppressed repeats from a committed chord must not abort its activation.
        var cancelsPendingActivation: Bool { action != nil || !consume }
    }
    private(set) var active = false
    private(set) var sessionID: UInt64?
    private var nextSessionID: UInt64 = 0
    private var swallowed = Set<UInt16>()

    mutating func key(code: UInt16, down: Bool, flags: CGEventFlags, text: String = "") -> Result {
        if !down { return Result(consume: swallowed.remove(code) != nil) }
        // A held Escape/Return/Tab must not start repeating into the source app
        // after this session has already committed or cancelled.
        if !active && swallowed.contains(code) { return Result(consume: true) }
        let matches = matchesBaseModifiers(flags)
        if UInt32(code) == hotkey.keyCode, matches {
            swallowed.insert(code)
            let backwards = flags.contains(.maskShift)
            let action: Action = active ? .step(backwards: backwards) : .begin(backwards: backwards)
            if !active { nextSessionID &+= 1; sessionID = nextSessionID }
            active = true
            return Result(consume: true, action: action, sessionID: sessionID)
        }
        // Keep a released-modifier invocation cancellable while discovery or
        // activation is pending, even though the overlay is already hidden.
        guard let id = sessionID else { return Result() }
        if !active && code != 53 {
            sessionID = nil
            return Result(action: .cancel, sessionID: id)
        }
        if !matches && code != 53 {
            active = false; sessionID = nil
            return Result(action: .cancel, sessionID: id)
        }
        let action: Action
        switch code {
        case 53: action = .cancel; active = false; sessionID = nil
        case 36, 76: action = .commit; active = false
        case 123, 126: action = .step(backwards: true)
        case 124, 125: action = .step(backwards: false)
        case 51 where active: action = .deleteSearch
        default:
            if active && matches && !text.isEmpty && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                swallowed.insert(code)
                return Result(consume: true, action: .search(text), sessionID: id)
            }
            active = false
            sessionID = nil
            return Result(action: .cancel, sessionID: id)
        }
        swallowed.insert(code)
        return Result(consume: true, action: action, sessionID: id)
    }

    mutating func modifiers(flags: CGEventFlags) -> Result {
        guard active, flags.intersection(requiredFlags) != requiredFlags else { return Result() }
        active = false
        return Result(action: .commit, sessionID: sessionID)
    }

    /// Deferred cleanup for an earlier invocation cannot reset a newer chord.
    mutating func finish(session id: UInt64) {
        guard sessionID == id else { return }
        active = false; sessionID = nil
    }
    mutating func reset() { active = false; sessionID = nil; swallowed.removeAll() }
}
