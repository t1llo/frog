import SwiftUI

/// The bar along the bottom of a Frog panel: which panel this is, what Return does, and where the actions are.
struct PanelFooter: View {
    let symbol: String
    let name: String
    /// The selected row's primary action; nil hides the Return hint.
    var primaryTitle: String?
    var showsActions = true
    /// What Escape does, for a panel without actions; nil hides the hint.
    var closeTitle: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(FrogType.label)
            Text(L10n.text(name)).font(FrogType.label).lineLimit(1)
            Spacer(minLength: 12)
            if let primaryTitle {
                Text(L10n.text(primaryTitle)).font(FrogType.label).foregroundStyle(FrogStyle.ink).lineLimit(1)
                KeyCap("↩")
            }
            if showsActions {
                Text(L10n.text("Actions")).font(FrogType.label).foregroundStyle(FrogStyle.ink)
                    .padding(.leading, primaryTitle != nil ? 8 : 0)
                HStack(spacing: 3) { KeyCap("⌘"); KeyCap("K") }
            }
            if let closeTitle {
                Text(L10n.text(closeTitle)).font(FrogType.label).foregroundStyle(FrogStyle.ink).lineLimit(1)
                    .padding(.leading, primaryTitle != nil || showsActions ? 8 : 0)
                KeyCap("esc")
            }
        }
        .foregroundStyle(FrogStyle.muted)
        .padding(.horizontal, FrogStyle.cardPadding)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        // Rex's sheet footer: the panel's own colour under a thin line.
        .overlay(alignment: .top) { Rectangle().fill(FrogStyle.hairline).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let primaryTitle { parts.append("\(L10n.text(primaryTitle)), \(L10n.text("Return"))") }
        if showsActions { parts.append("\(L10n.text("Actions")), \(L10n.text("Command K"))") }
        if let closeTitle { parts.append("\(L10n.text(closeTitle)), \(L10n.text("Escape"))") }
        return parts.isEmpty ? L10n.text(name) : parts.joined(separator: ". ")
    }
}

/// One key of a shortcut, drawn as a small cap: 18 points tall and at least as wide, so ⌘ and K are the same
/// square and a word key (Space, esc) grows only sideways. Hints in footers and lists use caps; a recorded
/// shortcut that can be clicked to change is a `ShortcutBadge` chip instead.
struct KeyCap: View {
    static let size: CGFloat = 18
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key).font(FrogType.label).foregroundStyle(FrogStyle.muted).lineLimit(1).fixedSize()
            .padding(.horizontal, FrogStyle.space4)
            .frame(minWidth: Self.size, minHeight: Self.size, maxHeight: Self.size)
            .background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius, style: .continuous))
    }
}

/// A whole shortcut as caps, one per key: "⌃⌥Space" is ⌃, ⌥ and Space. Modifier glyphs each take a cap; what
/// follows them is the key.
struct KeyCaps: View {
    let keys: [String]
    init(_ shortcut: String) { keys = Self.split(shortcut) }

    var body: some View {
        HStack(spacing: 3) { ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap($0.element) } }
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
