import FrogCore
import SwiftUI

/// A rule's tile: the glyph its name says (`SelectionBubbleItems.symbol(for:)`) on a colour of its kind, so rules side
/// by side read apart at a glance: proofreading green, translating blue, email orange, defining and explaining teal,
/// summing up purple, shortening pink, polishing indigo. A translation names its language instead of a globe ("EN",
/// "DE"), since two globes turned a little differently look alike at list size.
struct RuleIconTile: View {
    /// What the tile is drawn from: the rule's name, its glyph and whether it answers in the panel.
    let name: String
    let symbol: String
    let answers: Bool
    var size: PluginIconTile.Size = .list
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(rule: Rule, size: PluginIconTile.Size = .list) {
        name = rule.name; symbol = SelectionBubbleItems.symbol(for: rule); answers = rule.answersInPanel; self.size = size
    }

    /// A rule as the selection bubble lists it, drawn as it is in Writing and the command bar.
    init(item: BubbleItem, size: PluginIconTile.Size = .sidebar) {
        name = item.title; symbol = item.symbol; answers = item.answers; self.size = size
    }

    var body: some View {
        let tint = Self.tint(name: name, symbol: symbol, answers: answers)
        if let code = Self.languageCode(name: name, symbol: symbol) {
            let shape = RoundedRectangle(cornerRadius: size == .sidebar ? FrogStyle.smallRadius : FrogStyle.controlRadius, style: .continuous)
            let fill = PluginIconTile.fill(for: tint.color, colorScheme: colorScheme, contrast: contrast) ?? tint.color
            Text(code)
                .font(.system(size: size.rawValue * 0.38, weight: .bold, design: .rounded)).tracking(0.2)
                .foregroundStyle(.white)
                .frame(width: size.rawValue, height: size.rawValue)
                .background(shape.fill(fill.gradient))
                .overlay(shape.strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
                .accessibilityHidden(true)
        } else {
            PluginIconTile(symbol: symbol, tint: tint.color, size: size)
        }
    }

    /// The colour of what the rule does, from the glyph its name gives it; a rule whose name says nothing known wears
    /// its feature's colour (Writing's green, Explain's teal for one that answers in the panel).
    static func tint(for rule: Rule) -> PluginTint {
        tint(name: rule.name, symbol: SelectionBubbleItems.symbol(for: rule), answers: rule.answersInPanel)
    }

    /// The Explain rule wears `answerSymbol`, whose kind is Explain's colour, so the glyph alone tells it apart.
    static func tint(name: String, symbol: String, answers: Bool) -> PluginTint {
        if languageCode(name: name, symbol: symbol) != nil { return .blue }
        if let kind = kinds.first(where: { $0.symbols.contains(symbol) }) { return kind.tint }
        return answers ? ExplainPlugin.info.tint : WritingPlugin.info.tint
    }

    /// The colour each kind of glyph wears.
    private static let kinds: [(symbols: Set<String>, tint: PluginTint)] = [
        (["translate", "globe.americas", "globe.europe.africa", "globe.asia.australia"], tint: .blue),
        (["envelope"], tint: .orange),
        (["book.closed", "questionmark.bubble"], tint: ExplainPlugin.info.tint),
        (["list.bullet"], tint: .purple),
        (["scissors"], tint: .pink),
        (["wand.and.stars"], tint: .indigo),
        (["lightbulb"], tint: .yellow),
        (["chevron.left.forwardslash.chevron.right"], tint: .gray),
        (["checkmark.circle", "text.magnifyingglass"], tint: WritingPlugin.info.tint),
    ]

    /// The two-letter code of the language a translation names ("Translate to German" is "DE"), or nil for any other
    /// rule and for a translation that names no language Frog knows.
    static func languageCode(for rule: Rule) -> String? {
        languageCode(name: rule.name, symbol: SelectionBubbleItems.symbol(for: rule))
    }

    /// A translation's glyph is never `answerSymbol`, which only the Explain rule and rules with no known name wear.
    static func languageCode(name: String, symbol: String) -> String? {
        guard symbol != SelectionBubbleItems.answerSymbol else { return nil }
        let name = name.lowercased()
        guard ["translat", "übersetz"].contains(where: name.contains) else { return nil }
        return languages.first { entry in entry.words.contains { name.contains($0) } }?.code
    }

    private static let languages: [(words: [String], code: String)] = [
        (["english", "englisch"], "EN"), (["german", "deutsch"], "DE"), (["french", "französisch"], "FR"),
        (["spanish", "spanisch"], "ES"), (["italian", "italienisch"], "IT"), (["portugu"], "PT"), (["dutch"], "NL"),
        (["polish"], "PL"), (["swedish"], "SV"), (["arabic"], "AR"), (["japanese"], "JA"), (["chinese"], "ZH"),
        (["korean"], "KO"), (["hindi"], "HI"), (["thai"], "TH"), (["vietnamese"], "VI"), (["indonesian"], "ID"),
    ]
}
