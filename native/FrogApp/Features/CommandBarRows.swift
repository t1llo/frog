import AppKit
import FrogCore

/// What a provider may use while building rows. Built once per `prepareResults`.
@MainActor struct CommandBarContext {
    let model: AppModel
    let frontPID: pid_t?
    let pasteboard: NSPasteboard
    let pasteTarget: (any ClipboardHistoryPasteTarget)?
    let waitForRelease: () async throws -> Void
    /// Writes the text to the bar's pasteboard, as the bar's own copy rows do.
    let copy: (String) -> Void
}

struct CommandRowAction {
    /// What the action does, in a word or two: "Copy result", "Paste", "Quit".
    var title: String
    /// When set, Return must be pressed twice within `CommandConfirmation.window`; the row shows this text meanwhile.
    var confirm: String? = nil
    var run: () async throws -> Void
}

struct CommandBarRow {
    enum Placement { case leading, ranked, trailing }
    var record: SearchRecord
    var placement: Placement = .ranked
    /// Nil for an informational row: choosing it does nothing and the bar stays open.
    var primary: CommandRowAction?
    /// What ⌘↩ runs instead of `primary`.
    var secondary: CommandRowAction? = nil
}

/// A source of command bar rows. The bar asks every provider in its list, in order.
@MainActor protocol CommandBarRowProviding: AnyObject {
    /// Rows for the catalogue, built in `prepareResults` with the other records and ranked by `CommandSearch`.
    /// `placement` is ignored here: catalogue rows are always ranked.
    func rows(in context: CommandBarContext) -> [CommandBarRow]
    /// Rows that depend on the typed text, rebuilt on every query change. `.leading` rows go above the ranked
    /// results in provider order, `.trailing` rows after them (after file results), `.ranked` is treated as
    /// `.trailing`. They are never remembered as recent choices.
    func queryRows(for query: String, in context: CommandBarContext) -> [CommandBarRow]
}

extension CommandBarRowProviding {
    func rows(in context: CommandBarContext) -> [CommandBarRow] { [] }
    func queryRows(for query: String, in context: CommandBarContext) -> [CommandBarRow] { [] }
}

/// The answer to an arithmetic or a unit conversion, above everything else it matches.
final class CalculationRows: CommandBarRowProviding {
    func queryRows(for query: String, in context: CommandBarContext) -> [CommandBarRow] {
        guard let answer = QuickCalculation.result(query) else { return [] }
        let copy = context.copy
        return [CommandBarRow(record: SearchRecord(id: "calculation:\(query)", title: answer, subtitle: "Calculation · Copy result", symbol: "equal.circle"),
                              placement: .leading, primary: CommandRowAction(title: "Copy result") { copy(answer) })]
    }
}

/// A few common emoji to copy.
final class EmojiRows: CommandBarRowProviding {
    private static let table = [("😀", "grinning smile happy"), ("🙂", "slightly smiling happy"), ("😂", "laugh tears joy"), ("❤️", "red heart love"),
                                ("👍", "thumbs up yes"), ("👎", "thumbs down no"), ("🎉", "party celebrate"), ("✅", "check done yes"),
                                ("❌", "cross no cancel"), ("🚀", "rocket launch"), ("🔥", "fire hot"), ("🐸", "frog"), ("🙏", "thank you please"),
                                ("🤔", "thinking"), ("👀", "eyes look"), ("✨", "sparkles"), ("💡", "idea bulb"), ("📌", "pin"), ("☕️", "coffee"), ("💻", "computer laptop")]

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let copy = context.copy
        return Self.table.map { symbol, words in
            CommandBarRow(record: SearchRecord(id: "emoji:\(symbol)", title: "\(symbol)  \(words.capitalized)", subtitle: "Emoji · Copy", keywords: "emoji \(words)", symbol: "face.smiling"),
                          primary: CommandRowAction(title: "Copy") { copy(symbol) })
        }
    }
}
