import Foundation
import FrogCore

enum HistoryFilter: String, CaseIterable, Identifiable {
    case text, audio, clipboard
    var id: Self { self }
    var title: String { switch self { case .text: "Text"; case .audio: "Audio"; case .clipboard: "Clipboard" } }
}

/// A display feed, never a persistence payload. Clipboard items remain in their
/// five-entry memory store rather than becoming saved transformation records.
enum HistoryItem: Identifiable, Equatable {
    case saved(HistoryEntry)
    case clipboard(ClipboardHistoryEntry)

    var id: UUID { switch self { case .saved(let entry): entry.id; case .clipboard(let entry): entry.id } }
    var timestamp: Date { switch self { case .saved(let entry): entry.timestamp; case .clipboard(let entry): entry.timestamp } }
    var title: String { switch self { case .saved(let entry): entry.ruleName; case .clipboard: "Clipboard history" } }
    var text: String { switch self { case .saved(let entry): entry.processedText; case .clipboard(let entry): entry.text } }
    var filter: HistoryFilter { switch self { case .saved(let entry): entry.category == .audio ? .audio : .text; case .clipboard: .clipboard } }
    var clipboardEntry: ClipboardHistoryEntry? { if case .clipboard(let entry) = self { entry } else { nil } }
    var savedEntry: HistoryEntry? { if case .saved(let entry) = self { entry } else { nil } }
    var requiresReveal: Bool { clipboardEntry != nil }

    func matches(_ query: String, revealed: Bool) -> Bool {
        guard !query.isEmpty else { return true }
        switch self {
        case .saved(let entry):
            return [entry.ruleName, entry.originalText, entry.processedText, entry.providerName, entry.model, entry.interruptionLabel ?? ""]
                .contains { $0.localizedStandardContains(query) }
        case .clipboard(let entry):
            // Hidden contents must not leak through search results before reveal.
            return ["Clipboard", "Memory only", entry.isSensitive ? "Sensitive" : "", revealed ? entry.text : ""]
                .contains { $0.localizedStandardContains(query) }
        }
    }
}

enum HistoryFeed {
    static func items(saved: [HistoryEntry], clipboard: [ClipboardHistoryEntry], filter: HistoryFilter? = nil,
                      search: String = "", revealed: Set<UUID> = []) -> [HistoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (saved.map(HistoryItem.saved) + clipboard.map(HistoryItem.clipboard))
            .filter { (filter == nil || $0.filter == filter) && $0.matches(query, revealed: revealed.contains($0.id)) }
            .sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp > $1.timestamp }
    }
}

extension HistoryEntry {
    var interruptionLabel: String? {
        switch interruption { case .escape: "Interrupted · Esc"; case .cancelled: "Interrupted"; case nil: nil }
    }
}
