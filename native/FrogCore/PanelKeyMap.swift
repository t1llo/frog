import Foundation

/// The modifier keys a panel looks at, kept free of AppKit so the key map stays testable.
public struct PanelModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = PanelModifiers(rawValue: 1 << 0)
    public static let shift = PanelModifiers(rawValue: 1 << 1)
    public static let option = PanelModifiers(rawValue: 1 << 2)
    public static let control = PanelModifiers(rawValue: 1 << 3)
}

/// What a panel knows about itself when a key arrives.
public struct PanelState: Equatable, Sendable {
    public var queryIsEmpty: Bool
    public var actionPanelOpen: Bool
    /// Whether Escape first clears a typed query before it closes the panel. Panels without a query field say false.
    public var clearsQueryOnEscape: Bool
    /// An input method is composing in the query field and needs every key for its candidates.
    public var composing: Bool
    public init(queryIsEmpty: Bool = true, actionPanelOpen: Bool = false, clearsQueryOnEscape: Bool = false, composing: Bool = false) {
        self.queryIsEmpty = queryIsEmpty
        self.actionPanelOpen = actionPanelOpen
        self.clearsQueryOnEscape = clearsQueryOnEscape
        self.composing = composing
    }
}

public enum PanelCommand: Equatable, Sendable {
    case moveUp, moveDown, runPrimary, runSecondary, runPlain, toggleActions, closeActions, clearQuery, close
    /// Runs the action at this index of the open action panel (⌘1 is 0).
    case runAction(Int)
    /// The key is not the panel's: the event goes on to the text field.
    case pass
}

/// One key convention for every Frog panel.
public enum PanelKeyMap {
    // Key codes are physical, layout-independent positions, so ⌘K, ⌘W, ⌃N and ⌃P follow their QWERTY places.
    static let returnKey: UInt16 = 36, keypadEnter: UInt16 = 76, escape: UInt16 = 53
    static let down: UInt16 = 125, up: UInt16 = 126
    static let k: UInt16 = 40, w: UInt16 = 13, n: UInt16 = 45, p: UInt16 = 35
    /// The digit keys 1 to 9 in order.
    static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    public static func decide(keyCode: UInt16, modifiers: PanelModifiers, state: PanelState) -> PanelCommand {
        if state.composing { return .pass }
        switch keyCode {
        case returnKey, keypadEnter:
            switch modifiers {
            case []: return .runPrimary
            case .command: return .runSecondary
            case .shift: return .runPlain
            default: return .pass  // ⌘⇧↩ and the rest are reserved.
            }
        case escape:
            if state.actionPanelOpen { return .closeActions }
            if !state.queryIsEmpty && state.clearsQueryOnEscape { return .clearQuery }
            return .close
        case down where modifiers.isEmpty: return .moveDown
        case up where modifiers.isEmpty: return .moveUp
        case n where modifiers == .control: return .moveDown
        case p where modifiers == .control: return .moveUp
        case k where modifiers == .command: return .toggleActions
        case w where modifiers == .command: return .close
        default:
            if state.actionPanelOpen, modifiers == .command, let index = digits.firstIndex(of: keyCode) {
                return .runAction(index)
            }
            return .pass
        }
    }
}
