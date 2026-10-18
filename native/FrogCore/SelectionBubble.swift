import CoreGraphics
import Foundation

/// The modifier keys the selection bubble looks at. Never characters.
public struct BubbleModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = BubbleModifiers(rawValue: 1 << 0)
    public static let command = BubbleModifiers(rawValue: 1 << 1)
    public static let option = BubbleModifiers(rawValue: 1 << 2)
    public static let control = BubbleModifiers(rawValue: 1 << 3)
}

/// One global event, reduced to what the bubble needs. A key press carries its key code and modifier keys only, so no
/// input can hold typed characters.
public enum SelectionInput: Equatable, Sendable {
    case mouseDown(CGPoint, clickCount: Int, right: Bool)
    case mouseUp(CGPoint, clickCount: Int, modifiers: BubbleModifiers)
    /// Shift went up while no mouse button was down: the end of a keyboard selection.
    case shiftReleased
    /// Delivered only while the bubble is visible.
    case keyDown(keyCode: UInt16, modifiers: BubbleModifiers = [])
    case scroll
    case applicationChanged
}

public enum SelectionGesture: Equatable, Sendable { case drag, doubleClick, tripleClick, shiftClick, keyboard }

public struct SelectionBubbleOptions: Equatable, Sendable {
    public var doubleClick = true
    public var keyboard = true
    public var maxCharacters = 4_000
    /// Asks Chrome, Electron and similar apps to expose their text, which they hide until an assistive app asks.
    public var exposeText = true
    public var excludedApps: Set<String> = SelectionBubbleOptions.defaultExcludedApps
    public static let defaultExcludedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ]
    public static let characterRange = 100...20_000
    public init() {}
}

/// Decides which gestures finish a selection, from mouse and Shift events alone.
public struct SelectionGestureTracker {
    public enum Decision: Equatable, Sendable { case none, dismiss(escape: Bool), schedule(SelectionGesture) }

    /// How far the pointer must move between mouse down and up to count as a drag.
    public static let dragDistance: CGFloat = 4
    public static let escapeKeyCode: UInt16 = 53

    private var down: CGPoint?
    /// The decision of a mouse up made with Shift held. Releasing Shift right after it repeats that decision rather
    /// than starting a keyboard selection, so a Shift-click keeps its pointer position and a ⌘⇧-click stays ignored.
    private var mouseUpWithShift: Decision?

    public init() {}

    public mutating func receive(_ input: SelectionInput, options: SelectionBubbleOptions) -> Decision {
        let afterMouse = mouseUpWithShift
        mouseUpWithShift = nil
        switch input {
        case let .mouseDown(point, _, _):
            down = point
            return .dismiss(escape: false)
        case let .mouseUp(point, clickCount, modifiers):
            let decision = release(point, clickCount: clickCount, modifiers: modifiers, options: options)
            if modifiers.contains(.shift) { mouseUpWithShift = decision }
            return decision
        case .shiftReleased:
            if let afterMouse { return afterMouse }
            return options.keyboard ? .schedule(.keyboard) : .none
        case let .keyDown(keyCode, _):
            return .dismiss(escape: keyCode == Self.escapeKeyCode)
        case .scroll, .applicationChanged:
            return .dismiss(escape: false)
        }
    }

    private mutating func release(_ point: CGPoint, clickCount: Int, modifiers: BubbleModifiers,
                                 options: SelectionBubbleOptions) -> Decision {
        let start = down
        down = nil
        if modifiers.contains(.command) { return .none }
        if let start, hypot(point.x - start.x, point.y - start.y) >= Self.dragDistance { return .schedule(.drag) }
        if clickCount >= 2 { return options.doubleClick ? .schedule(clickCount == 2 ? .doubleClick : .tripleClick) : .none }
        if clickCount == 1, modifiers.contains(.shift) { return .schedule(.shiftClick) }
        return .none
    }
}

/// The watcher's decisions with time passed in, so a settle can be cancelled and expire without timers.
public struct SelectionWatcherCore {
    public static let settle: TimeInterval = 0.3
    public static let idleDismiss: TimeInterval = 6

    public enum Effect: Equatable, Sendable {
        case cancelPending
        case scheduleRead(token: Int, at: Date, gesture: SelectionGesture)
        case dismiss(rememberShown: Bool)
    }

    /// The selection last dismissed with Escape. The same selection does not bring the bubble back.
    public private(set) var dismissedFingerprint: SelectionFingerprint?
    public private(set) var shownFingerprint: SelectionFingerprint?
    /// The selection the bubble showed last, kept after it went away until a plain click or a key takes it away. A
    /// gesture that did not select it again does not bring the bubble back for it.
    public private(set) var offeredFingerprint: SelectionFingerprint?
    public private(set) var pendingToken: Int?
    private var tracker = SelectionGestureTracker()
    private var nextToken = 0
    private var lastActivity: Date?

    public init() {}

    public mutating func receive(_ input: SelectionInput, now: Date, options: SelectionBubbleOptions) -> [Effect] {
        var effects: [Effect] = []
        if pendingToken != nil {
            pendingToken = nil
            effects.append(.cancelPending)
        }
        let decision = tracker.receive(input, options: options)
        if Self.deselects(input, decision: decision) { offeredFingerprint = nil }
        switch decision {
        case .none:
            break
        case let .dismiss(escape):
            let remember = escape && shownFingerprint != nil
            if remember { dismissedFingerprint = shownFingerprint }
            hidden()
            effects.append(.dismiss(rememberShown: remember))
        case let .schedule(gesture):
            nextToken += 1
            pendingToken = nextToken
            effects.append(.scheduleRead(token: nextToken, at: now.addingTimeInterval(Self.settle), gesture: gesture))
        }
        return effects
    }

    /// A plain click, or a key without Command or Control such as an arrow key, takes a text selection away, so the
    /// same text selected after it is selected anew, wherever that gesture ends. A drag, a scroll, a shortcut and an
    /// app switch may leave it as it was.
    private static func deselects(_ input: SelectionInput, decision: SelectionGestureTracker.Decision) -> Bool {
        switch input {
        case let .mouseUp(_, clickCount, modifiers):
            return decision == .none && clickCount == 1 && modifiers.isEmpty
        case let .keyDown(keyCode, modifiers):
            return keyCode != SelectionGestureTracker.escapeKeyCode && modifiers.isDisjoint(with: [.command, .control])
        default:
            return false
        }
    }

    /// Whether a settle that fired may read. False when a later input cancelled it.
    public mutating func settleFired(token: Int) -> Bool {
        guard pendingToken == token else { return false }
        pendingToken = nil
        return true
    }

    public mutating func shown(_ fingerprint: SelectionFingerprint, now: Date) {
        shownFingerprint = fingerprint
        offeredFingerprint = fingerprint
        lastActivity = now
    }

    /// The bubble went away for a reason the watcher did not see itself: an action, or idle dismissal.
    public mutating func hidden() {
        shownFingerprint = nil
        lastActivity = nil
    }

    /// A rule ran on the selection some other way, such as its shortcut: the bubble goes and a pending read is
    /// dropped, so the bubble does not appear next to the rule's own result.
    public mutating func interrupted() {
        pendingToken = nil
        hidden()
    }

    public mutating func hovered(now: Date) {
        guard shownFingerprint != nil else { return }
        lastActivity = now
    }

    /// True six seconds after the bubble appeared or was last hovered.
    public func shouldIdleDismiss(now: Date) -> Bool {
        guard shownFingerprint != nil, let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= Self.idleDismiss
    }
}

/// What the bubble checks before reading the selection.
public struct BubbleContext: Sendable {
    public var explainEnabled: Bool
    public var bubbleEnabled: Bool
    public var writingEnabled: Bool
    public var accessibilityTrusted: Bool
    public var frogFrontmost: Bool
    public var secureInput: Bool
    public var bundleID: String?
    public var isGame: Bool
    /// A rule is processing, dictation is running, a shortcut is being recorded, or the answer panel is key.
    public var busy: Bool

    public init(explainEnabled: Bool, bubbleEnabled: Bool, writingEnabled: Bool, accessibilityTrusted: Bool,
                frogFrontmost: Bool, secureInput: Bool, bundleID: String?, isGame: Bool, busy: Bool) {
        self.explainEnabled = explainEnabled; self.bubbleEnabled = bubbleEnabled; self.writingEnabled = writingEnabled
        self.accessibilityTrusted = accessibilityTrusted; self.frogFrontmost = frogFrontmost
        self.secureInput = secureInput; self.bundleID = bundleID; self.isGame = isGame; self.busy = busy
    }
}

/// Why the bubble does not read or does not show.
public enum BubbleBlock: Equatable, Sendable {
    case off, needsAccessibility, frogFrontmost, secureInput, excluded, game, busy
    case secureField, empty, tooLong, dismissedBefore, noItems, alreadyShowing
    /// The selection the bubble offered last, left as it was by a gesture that did not select it again.
    case unchanged
}

public enum SelectionBubblePolicy {
    /// Checked before any Accessibility call, first block wins.
    public static func mayRead(_ context: BubbleContext, options: SelectionBubbleOptions) -> BubbleBlock? {
        if !context.explainEnabled || !context.bubbleEnabled { return .off }
        if !context.accessibilityTrusted { return .needsAccessibility }
        if context.frogFrontmost { return .frogFrontmost }
        if context.secureInput { return .secureInput }
        if let bundleID = context.bundleID, options.excludedApps.contains(bundleID) { return .excluded }
        if context.isGame { return .game }
        if context.busy { return .busy }
        return nil
    }

    /// Checked after the read. `alreadyShowing` means the bubble stays as it is. `offered` is the selection the
    /// bubble showed last; `reselected` tells whether the gesture may have selected the text again.
    public static func mayShow(_ result: SelectionReadResult, dismissed: SelectionFingerprint?,
                               shown: SelectionFingerprint?, offered: SelectionFingerprint? = nil, reselected: Bool = true,
                               itemCount: Int) -> BubbleBlock? {
        let snapshot: SelectionSnapshot
        switch result {
        case .secure: return .secureField
        case .empty, .unavailable: return .empty
        case .tooLong: return .tooLong
        case let .selection(read): snapshot = read
        }
        if snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if snapshot.fingerprint == dismissed { return .dismissedBefore }
        if snapshot.fingerprint == shown { return .alreadyShowing }
        if snapshot.fingerprint == offered, !reselected { return .unchanged }
        if itemCount == 0 { return .noItems }
        return nil
    }

    /// How far from its selection a mouse gesture may end and still count as having made it.
    public static let reselectionMargin: CGFloat = 24

    /// Whether a gesture may have selected the text it read again. A drag or click that selects ends on or next to
    /// its selection; dragging a window or a scroll bar ends away from a selection it leaves as it was. A mouse
    /// gesture whose selection reports no rectangle always counts. A keyboard gesture, without a pointer, counts
    /// unless Command or Control went down while Shift was held (`afterShortcut`), as for ⇧⌘T, which leaves the
    /// selection as it was. Cocoa coordinates.
    public static func reselects(pointer: CGPoint?, afterShortcut: Bool, bounds: CGRect?, endBounds: CGRect?) -> Bool {
        guard let pointer else { return !afterShortcut }
        let rects = [bounds, endBounds].compactMap { $0 }
        guard !rects.isEmpty else { return true }
        return rects.contains { $0.insetBy(dx: -reselectionMargin, dy: -reselectionMargin).contains(pointer) }
    }

    /// From the app's `LSApplicationCategoryType`, such as `public.app-category.action-games`.
    public static func isGame(applicationCategory: String?) -> Bool {
        applicationCategory?.lowercased().contains("games") ?? false
    }

    /// VS Code and the editors built on it take an app that asks for their text for a screen reader: with
    /// `editor.accessibilitySupport` on `auto`, its default, they switch to their screen reader mode, which changes
    /// how the editor behaves and plays sounds. So they are never asked.
    public static let codeEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]

    /// Whether the bubble may ask an app to expose its text. `builtOnVSCode` is true for an app that ships VS
    /// Code's product file, which catches the editors not listed by name.
    public static func mayAskToExposeText(bundleID: String?, builtOnVSCode: Bool) -> Bool {
        !builtOnVSCode && !(bundleID.map(codeEditors.contains) ?? false)
    }

    /// The status line on the Explain page.
    public static func status(explainEnabled: Bool, bubbleEnabled: Bool, accessibilityTrusted: Bool) -> String? {
        guard bubbleEnabled else { return nil }
        guard explainEnabled else { return "Turn on Explain to use the selection bubble" }
        guard accessibilityTrusted else {
            return "Needs Accessibility: allow Frog in System Settings → Privacy & Security → Accessibility"
        }
        return "On: select text in another app to see Explain"
    }
}

public struct BubbleItem: Equatable, Identifiable, Sendable {
    /// The rule's ID.
    public var id: UUID
    public var title: String
    public var symbol: String
    /// An answer rule, shown in the answer panel; otherwise a Writing rule that replaces the selection.
    public var answers: Bool
    /// The rule's own shortcut, shown beside it in the full list.
    public var hotkey: Hotkey?

    public init(id: UUID, title: String, symbol: String, answers: Bool, hotkey: Hotkey? = nil) {
        self.id = id; self.title = title; self.symbol = symbol; self.answers = answers; self.hotkey = hotkey
    }
}

public enum SelectionBubbleItems {
    public static let answerSymbol = "questionmark.bubble"
    public static let writingSymbol = "text.alignleft"

    /// Every rule the bubble can offer, in its order: answer rules with Explain leading, then Writing rules. The
    /// Explain page lists these to choose which ones the bubble shows. Explain is the one answer rule Frog adds
    /// itself, so it leads under any name the person gives it.
    public static func candidates(rules: [Rule], explainEnabled: Bool, writingEnabled: Bool) -> [Rule] {
        var all: [Rule] = []
        if explainEnabled {
            let answers = rules.filter { $0.enabled && $0.answersInPanel }
            all += answers.filter(\.preset) + answers.filter { !$0.preset }
        }
        if writingEnabled {
            all += rules.filter { $0.enabled && $0.category == .text && !$0.answersInPanel }
        }
        return all
    }

    /// The candidates the person did not hide, Writing rules only in an editable field. Past `visibleLimit` items,
    /// one slot goes to More and the rest wait behind it.
    public static func items(rules: [Rule], explainEnabled: Bool, writingEnabled: Bool, editable: Bool,
                             hidden: Set<UUID> = [], configured: (Rule) -> Bool,
                             visibleLimit: Int = 4) -> (visible: [BubbleItem], more: [BubbleItem]) {
        let all = candidates(rules: rules, explainEnabled: explainEnabled, writingEnabled: writingEnabled)
            .filter { !hidden.contains($0.id) && ($0.answersInPanel || editable) && configured($0) }
            .map { BubbleItem(id: $0.id, title: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                              symbol: $0.answersInPanel ? answerSymbol : writingSymbol, answers: $0.answersInPanel,
                              hotkey: $0.hotkey) }
        guard all.count > visibleLimit else { return (all, []) }
        let shown = max(visibleLimit - 1, 0)
        return (Array(all.prefix(shown)), Array(all.dropFirst(shown)))
    }
}

public enum BundleIdentifiers {
    public static let maximumCount = 200
    public static let message = "Use app bundle identifiers such as com.apple.TextEdit, at most 200."
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")

    public static func isValid(_ id: String) -> Bool {
        (1...255).contains(id.unicodeScalars.count) && id.contains(".")
            && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func validate(_ ids: [String]) throws {
        guard ids.count <= maximumCount, ids.allSatisfy(isValid) else { throw FrogError.message(message) }
    }
}
