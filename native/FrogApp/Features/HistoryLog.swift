import Foundation
import FrogCore

/// Taken when work starts that may end in a History entry. Recording with it does nothing once History was
/// turned off or cleared since, so an answer that outlives Clear all is not saved after it.
struct HistoryTicket: Equatable {
    let epoch: UUID?
}

/// The History plugin's API: what rules, answers and dictation record through, and what its page and actions read.
/// Entries live in `history.json`. Copied text is the Clipboard plugin's and never comes here.
@MainActor
extension AppModel {
    func historyTicket() -> HistoryTicket {
        HistoryTicket(epoch: configuration.preferences.historyEnabled ? historyEpoch : nil)
    }

    /// Saves `entry` while History is on and was not cleared since `ticket`. False when nothing was saved.
    @discardableResult
    func recordHistory(_ entry: HistoryEntry, ticket: HistoryTicket) throws -> Bool {
        guard accepts(ticket), let retained = try historyStore.append(entry, preferences: configuration.preferences) else { return false }
        adoptHistory(retained)
        return true
    }

    /// Replaces a saved entry, such as an answer with a new follow-up. False when it is gone.
    func updateHistory(_ entry: HistoryEntry, ticket: HistoryTicket) throws -> Bool {
        guard accepts(ticket) else { return false }
        let kept = try historyStore.update(entry, preferences: configuration.preferences)
        refreshHistory()
        return kept
    }

    /// Saved entries, newest first, narrowed by kind and words.
    func historyEntries(search: String = "", kind: HistoryFilter? = nil, limit: Int? = nil) -> [HistoryEntry] {
        Array(HistoryFeed.items(history, filter: kind, search: search).prefix(limit ?? .max))
    }

    func deleteHistory(id: UUID) throws {
        adoptHistory(try historyStore.delete(id: id, preferences: configuration.preferences))
    }

    /// Deletes every saved entry. Copied text belongs to the clipboard and stays.
    func clearHistory() throws {
        invalidateHistoryRecovery()
        try historyStore.clear(); refreshHistory()
    }

    private func accepts(_ ticket: HistoryTicket) -> Bool {
        configuration.preferences.historyEnabled && ticket.epoch != nil && ticket.epoch == historyEpoch
    }
}
