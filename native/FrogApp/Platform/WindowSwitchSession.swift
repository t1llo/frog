import Foundation

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
    mutating func reset() { windows = []; selected = nil }
}

/// Pure key routing: only the switcher's keys are consumed, never ordinary typing.
struct WindowSwitchKeyRouter {
    enum Action: Equatable { case begin(backwards: Bool), step(backwards: Bool), commit, cancel, search(String), deleteSearch }
    struct Result {
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

    mutating func key(code: UInt16, down: Bool, command: Bool, shift: Bool, otherModifiers: Bool, text: String = "") -> Result {
        if !down { return Result(consume: swallowed.remove(code) != nil) }
        // A held Escape/Return/Tab must not start repeating into the source app
        // after this session has already committed or cancelled.
        if !active && swallowed.contains(code) { return Result(consume: true) }
        if code == 48, command, !otherModifiers {
            swallowed.insert(code)
            let action: Action = active ? .step(backwards: shift) : .begin(backwards: shift)
            if !active { nextSessionID &+= 1; sessionID = nextSessionID }
            active = true
            return Result(consume: true, action: action, sessionID: sessionID)
        }
        // Keep a released-command invocation cancellable while discovery or
        // activation is pending, even though the overlay is already hidden.
        guard let id = sessionID else { return Result() }
        if !active && code != 53 {
            sessionID = nil
            return Result(action: .cancel, sessionID: id)
        }
        let action: Action
        switch code {
        case 53: action = .cancel; active = false; sessionID = nil
        case 36, 76: action = .commit; active = false
        case 123, 126: action = .step(backwards: true)
        case 124, 125: action = .step(backwards: false)
        case 51 where active && command: action = .deleteSearch
        default:
            if active && command && !otherModifiers && !text.isEmpty && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
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

    mutating func modifiers(command: Bool) -> Result {
        guard active, !command else { return Result() }
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
