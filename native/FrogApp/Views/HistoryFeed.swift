import Foundation
import FrogCore

/// The kinds History tells apart. Copied text is not one of them: it has the Clipboard page.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case text, answers, audio
    var id: Self { self }
    var title: String { switch self { case .text: "Text"; case .answers: "Answers"; case .audio: "Audio" } }

    /// Answers appears while Explain is on, and stays while saved answers remain.
    static func visible(explainEnabled: Bool, hasAnswers: Bool) -> [HistoryFilter] {
        allCases.filter { $0 != .answers || explainEnabled || hasAnswers }
    }
}

/// Saved entries as History lists them: newest first, narrowed by kind and search.
enum HistoryFeed {
    static func items(_ entries: [HistoryEntry], filter: HistoryFilter? = nil, search: String = "") -> [HistoryEntry] {
        narrowed(entries.sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp > $1.timestamp },
                 filter: filter, search: search)
    }

    /// Narrows a feed that `items` already sorted. The order is kept, so a view builds the feed once per pass and
    /// derives the list it shows from it.
    static func narrowed(_ items: [HistoryEntry], filter: HistoryFilter?, search: String) -> [HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard filter != nil || !query.isEmpty else { return items }
        return items.filter { (filter == nil || $0.kind == filter) && $0.matches(query) }
    }
}

extension HistoryEntry {
    var kind: HistoryFilter { answer != nil ? .answers : category == .audio ? .audio : .text }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return ([ruleName, originalText, processedText, providerName, model, interruptionLabel ?? ""] + answerSearchTexts)
            .contains { $0.localizedStandardContains(query) }
    }

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
