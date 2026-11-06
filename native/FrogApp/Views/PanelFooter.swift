import SwiftUI
import FrogCore

/// The one footer of every popup and floating panel: on the footer band, a muted status on the leading side (which
/// panel this is, a count, "Updated 15m ago", "Live") and the actions on the trailing side, each a word in the text
/// colour followed by its keys as caps ("Paste ↩", "Close esc"). `PanelFooter`, `FrogPopupFooter`, the Frog menu and
/// clipboard history all draw this; nothing else draws a footer.
struct FrogFooter<Status: View, Actions: View>: View {
    /// Where the footer sits: `.panel` along the bottom of a popup or floating panel, whose hint buttons reach past
    /// the band's inset with their hover fill; `.card` along the bottom of a card (the Notes and Scripts editor),
    /// whose actions are controls that end on the card's content edge.
    enum Placement { case panel, card }

    var placement: Placement = .panel
    @ViewBuilder var status: Status
    @ViewBuilder var actions: Actions

    init(_ placement: Placement = .panel, @ViewBuilder status: () -> Status, @ViewBuilder actions: () -> Actions) {
        self.placement = placement; self.status = status(); self.actions = actions()
    }

    var body: some View {
        HStack(spacing: FrogStyle.space8) {
            // The status keeps its room first: it is laid out before the actions, which give way by dropping their
            // words and keeping their caps (`FrogFooterHint`); the actions in turn come before the spacer, so they
            // keep their words whenever the row has room for them.
            HStack(spacing: FrogStyle.space6) { status }
                .font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1).layoutPriority(2)
            Spacer(minLength: FrogStyle.space8)
            // Hints that are buttons reach past the edge only with their hover fill; their own 6-point padding is
            // the gap between them.
            HStack(spacing: FrogStyle.space4) { actions }
                .padding(.trailing, placement == .panel ? -FrogStyle.space6 : 0).layoutPriority(1)
        }
        .frogFooterBand()
        .accessibilityElement(children: .contain)
    }
}

/// One action in a `FrogFooter`: its word and its keys as caps. With `action` it is a button for the pointer and
/// VoiceOver, with a hover fill; without, a hint for the keyboard.
struct FrogFooterHint: View {
    let title: String
    let keys: String
    var action: (() -> Void)? = nil
    init(_ title: String, keys: String, action: (() -> Void)? = nil) { self.title = title; self.keys = keys; self.action = action }

    var body: some View {
        if let action {
            Button(action: action) { label.frame(height: FrogStyle.compactHeight).contentShape(Rectangle()) }
                .buttonStyle(MenuRowStyle())
                .accessibilityLabel(L10n.text(title)).accessibilityHint(keys)
        } else {
            label.accessibilityElement(children: .ignore).accessibilityLabel("\(L10n.text(title)), \(keys)")
        }
    }

    /// The word and its caps, or only the caps where the footer is too narrow for both: the status keeps its room
    /// first, and the word stays in the tooltip.
    private var label: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: FrogStyle.space6) {
                Text(L10n.text(title)).font(FrogType.label).foregroundStyle(FrogStyle.ink).lineLimit(1)
                // An action without keys (Stop on a rule with no shortcut) is its word alone.
                if !keys.isEmpty { KeyCaps(keys) }
            }.padding(.horizontal, FrogStyle.space6).fixedSize()
            if !keys.isEmpty { KeyCaps(keys).padding(.horizontal, FrogStyle.space6).fixedSize().help(L10n.text(title)) }
        }
    }
}

/// The footer of a keyboard panel (command bar, window switcher, layout picker): which panel this is, with its icon
/// and, muted after a `·`, a count ("Window switcher · 23 windows"), then what Return, ⌘K and Escape do. Every
/// launcher and panel footer reads this way: the surface's name and icon on the left, primary ↩, Actions ⌘K and
/// Close esc on the right.
struct PanelFooter: View {
    let symbol: String
    let name: String
    /// A count or state after the name ("23 windows").
    var detail: String? = nil
    /// The selected row's primary action; nil hides the Return hint.
    var primaryTitle: String?
    var showsActions = true
    /// What Escape does, for a panel without actions; nil hides the hint.
    var closeTitle: String? = nil

    var body: some View {
        FrogFooter {
            Image(systemName: symbol).font(FrogType.label)
            // One text, so the dot sits evenly between the name and its count.
            Text(verbatim: [L10n.text(name), detail].compactMap { $0 }.joined(separator: " · ")).monospacedDigit()
        } actions: {
            if let primaryTitle { FrogFooterHint(primaryTitle, keys: "↩") }
            if showsActions { FrogFooterHint("Actions", keys: "⌘K") }
            if let closeTitle { FrogFooterHint(closeTitle, keys: "esc") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let primaryTitle { parts.append("\(L10n.text(primaryTitle)), \(L10n.text("Return"))") }
        if showsActions { parts.append("\(L10n.text("Actions")), \(L10n.text("Command K"))") }
        if let closeTitle { parts.append("\(L10n.text(closeTitle)), \(L10n.text("Escape"))") }
        let title = [L10n.text(name), detail].compactMap { $0 }.joined(separator: ", ")
        return parts.isEmpty ? title : ([title] + parts).joined(separator: ". ")
    }
}

extension View {
    /// The bottom bar of a popup or floating panel (`PanelFooter`, `FrogPopupFooter`, a menu tab's footer): 32
    /// tall, content `cardPadding` in, on `FrogStyle.footerBand`, a shade darker than the panel, which sets it apart
    /// without a line. The panel's own shape clips the band's lower corners.
    func frogFooterBand() -> some View {
        padding(.horizontal, FrogStyle.cardPadding)
            .frame(height: 32).frame(maxWidth: .infinity)
            .background(FrogStyle.footerBand)
    }
}

/// One key of a shortcut, drawn as a small cap: 18 points tall and at least as wide, so ⌘ and K are the same
/// square and a word key (Space, esc) grows only sideways. Every shortcut Frog shows is caps, one per key
/// (`KeyCaps`): in footers, lists, rows and the shortcut reference. Only a `HotkeyRecorder` that is recording
/// draws a pill.
struct KeyCap: View {
    static let size: CGFloat = 18
    /// The smaller cap a long shortcut falls back to where its full caps do not fit, as in a layout tile.
    static let compactSize: CGFloat = 15
    let key: String
    var compact = false
    init(_ key: String, compact: Bool = false) { self.key = key; self.compact = compact }

    var body: some View {
        let size = compact ? Self.compactSize : Self.size
        // A single glyph (⌘, ↩, K) is exactly a square, whatever the glyph's own width, so the caps of every row end
        // and line up on one edge; only a word key (Space, esc) grows sideways.
        let single = key.count == 1
        // The glyph in the text colour, softened: `muted` on the cap's fill fell under 4.5:1 in dark themes.
        Text(key).font(compact ? FrogType.caption : FrogType.label).foregroundStyle(FrogStyle.ink.opacity(0.8)).lineLimit(1).fixedSize()
            .padding(.horizontal, single ? 0 : compact ? FrogStyle.space2 : FrogStyle.space4)
            .frame(minWidth: size, maxWidth: single ? size : nil, minHeight: size, maxHeight: size)
            .background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius, style: .continuous))
    }
}

/// A whole shortcut as caps, one per key: "⌃⌥Space" is ⌃, ⌥ and Space. Modifier glyphs each take a cap; what
/// follows them is the key.
struct KeyCaps: View {
    let keys: [String]
    /// Smaller caps, closer together; `fitting` falls back to them.
    var compact = false
    init(_ shortcut: String, compact: Bool = false) { keys = Self.split(shortcut); self.compact = compact }
    /// A recorded shortcut, as `HotkeyManager` names its keys.
    init(hotkey: Hotkey) { keys = HotkeyManager.keys(hotkey) }
    init(_ keys: [String], compact: Bool = false) { self.keys = keys; self.compact = compact }
    init(keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: compact ? FrogStyle.space2 : 3) { ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap($0.element, compact: compact) } }
            .accessibilityElement(children: .ignore).accessibilityLabel(keys.joined())
    }

    static func split(_ shortcut: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var keys: [String] = [], rest = Substring(shortcut.trimmingCharacters(in: .whitespaces))
        while let first = rest.first, modifiers.contains(first) {
            keys.append(String(first)); rest = rest.dropFirst()
        }
        let key = rest.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { keys.append(key) }
        return keys
    }
}

/// A hint that names keys ("⌥Space to stop · Esc to cancel"), with each shortcut drawn as caps, one per key, and the
/// words between them muted: the same caps as every footer, never a shortcut written as text. Parts are split at
/// " · "; a word is a shortcut when it starts with a modifier glyph or is Esc, Return or Tab.
struct KeyHintLine: View {
    let text: String

    var body: some View {
        HStack(spacing: FrogStyle.space4) {
            ForEach(Array(Self.parts(text).enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·").padding(.horizontal, FrogStyle.space2) }
                ForEach(Array(part.enumerated()), id: \.offset) { _, word in
                    if Self.isShortcut(word) { KeyCaps(word == "Esc" ? "esc" : word) } else { Text(word) }
                }
            }
        }
        .font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }

    /// The parts of the hint, each a list of runs: a shortcut, or the words between shortcuts.
    static func parts(_ text: String) -> [[String]] {
        text.components(separatedBy: " · ").map { part in
            var runs: [String] = [], words: [String] = []
            for word in part.split(separator: " ").map(String.init) {
                if isShortcut(word) {
                    if !words.isEmpty { runs.append(words.joined(separator: " ")); words = [] }
                    runs.append(word)
                } else { words.append(word) }
            }
            if !words.isEmpty { runs.append(words.joined(separator: " ")) }
            return runs
        }
    }

    static func isShortcut(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return "⌃⌥⇧⌘".contains(first) || ["Esc", "esc", "Return", "↩", "Tab", "⇥"].contains(word)
    }
}
