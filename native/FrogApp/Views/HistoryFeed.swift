import Foundation
import FrogCore

enum HistoryFilter: String, CaseIterable, Identifiable {
    case text, answers, audio, clipboard
    var id: Self { self }
    var title: String { switch self { case .text: "Text"; case .answers: "Answers"; case .audio: "Audio"; case .clipboard: "Clipboard" } }

    /// The filters History offers; copied text has the Clipboard page. Answers appears while Explain is on, and stays
    /// while saved answers remain.
    static func visible(explainEnabled: Bool, hasAnswers: Bool) -> [HistoryFilter] {
        allCases.filter { $0 != .clipboard && ($0 != .answers || explainEnabled || hasAnswers) }
    }
}

/// A display feed, never a persistence payload. Clipboard items remain in their
/// bounded memory store rather than becoming saved transformation records.
enum HistoryItem: Identifiable, Equatable {
    case saved(HistoryEntry)
    case clipboard(ClipboardHistoryEntry)

    var id: UUID { switch self { case .saved(let entry): entry.id; case .clipboard(let entry): entry.id } }
    var timestamp: Date { switch self { case .saved(let entry): entry.timestamp; case .clipboard(let entry): entry.timestamp } }
    var title: String { switch self { case .saved(let entry): entry.ruleName; case .clipboard: "Clipboard history" } }
    var text: String { switch self { case .saved(let entry): entry.processedText; case .clipboard(let entry): entry.text } }
    var filter: HistoryFilter {
        switch self {
        case .saved(let entry): entry.answer != nil ? .answers : entry.category == .audio ? .audio : .text
        case .clipboard: .clipboard
        }
    }
    var clipboardEntry: ClipboardHistoryEntry? { if case .clipboard(let entry) = self { entry } else { nil } }
    var savedEntry: HistoryEntry? { if case .saved(let entry) = self { entry } else { nil } }
    var requiresReveal: Bool { clipboardEntry?.isSensitive == true }

    func matches(_ query: String, revealed: Bool) -> Bool {
        guard !query.isEmpty else { return true }
        switch self {
        case .saved(let entry):
            return ([entry.ruleName, entry.originalText, entry.processedText, entry.providerName, entry.model, entry.interruptionLabel ?? ""]
                    + entry.answerSearchTexts)
                .contains { $0.localizedStandardContains(query) }
        case .clipboard(let entry):
            // Hidden contents must not leak through search results before reveal.
            return ["Clipboard", "Memory only", entry.isSensitive ? "Sensitive" : "", !entry.isSensitive || revealed ? entry.text : ""]
                .contains { $0.localizedStandardContains(query) }
        }
    }
}

enum HistoryFeed {
    static func items(saved: [HistoryEntry], clipboard: [ClipboardHistoryEntry], filter: HistoryFilter? = nil,
                      search: String = "", revealed: Set<UUID> = []) -> [HistoryItem] {
        narrowed(saved.map(HistoryItem.saved) + clipboard.map(HistoryItem.clipboard), filter: filter, search: search, revealed: revealed)
            .sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp > $1.timestamp }
    }

    /// Narrows a feed that `items` already merged and sorted. The order is kept, so a view
    /// builds the feed once per pass and derives the list it shows from it.
    static func narrowed(_ items: [HistoryItem], filter: HistoryFilter?, search: String, revealed: Set<UUID>) -> [HistoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard filter != nil || !query.isEmpty else { return items }
        return items.filter { (filter == nil || $0.filter == filter) && $0.matches(query, revealed: revealed.contains($0.id)) }
    }
}

extension HistoryEntry {
    var interruptionLabel: String? {
        switch interruption { case .escape: "Interrupted · Esc"; case .cancelled: "Interrupted"; case nil: nil }
    }

    /// What search finds in an answer beyond the selection and the first answer.
    var answerSearchTexts: [String] {
        guard let answer else { return [] }
        return [answer.context, answer.application, answer.source].compactMap { $0 }
            + answer.followUps.flatMap { [$0.question, $0.answer] }
    }
}
