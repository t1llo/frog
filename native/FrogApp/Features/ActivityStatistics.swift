import Combine
import Foundation
import FrogCore

/// Completion hooks stay synchronous and ordered: a counted event is in `snapshot` when its
/// hook returns, and only saving it leaves the main thread. A statistics failure never fails a tool action.
@MainActor final class ActivityStatisticsStore: ObservableObject {
    @Published private(set) var snapshot = ActivityStatisticsSnapshot()
    @Published private(set) var issue: String? { didSet { issueIsFailedSave = false } }
    @Published private(set) var loaded = false
    /// Whether `issue` says that an event could not be saved, which the next saved event takes back.
    private var issueIsFailedSave = false
    private let persistence: ActivityStatisticsPersistence
    /// Serial, so events reach the file in the order they completed. Reading and replacing
    /// the file go through it too and therefore never overtake an event still being saved.
    private let writes: DispatchQueue

    init(directory: URL? = nil, writes: DispatchQueue = DispatchQueue(label: "frog.activity-statistics", qos: .utility)) {
        persistence = ActivityStatisticsPersistence(directory: directory)
        self.writes = writes
        reload()
    }

    func reload() {
        do { snapshot = try writes.sync { [persistence] in try persistence.load() }; loaded = true; issue = nil }
        catch { loaded = false; issue = error.localizedDescription }
    }

    /// Returns once every counted event is saved. Frog calls it before it quits.
    func waitForWrites() { writes.sync {} }

    func recordRuleExecution(kind: ActivityRuleKind) { record([.rule(kind)]) }

    /// Supply microphone capture time only, excluding model loading/transcription/insertion.
    /// Invoke only after a nonempty successful delivery, including intentional copy-only delivery.
    /// The run of the delivering rule, when given, is saved in the same transaction.
    func recordDictation(recordingSeconds: Double, text: String, rule: ActivityRuleKind? = nil) {
        guard loaded, snapshot.recordingEnabled else { return }
        let words = ActivityStatisticsSnapshot.wordCount(in: text)
        var events: [ActivityStatisticsEvent] = []
        if recordingSeconds.isFinite, recordingSeconds > 0, words > 0 { events.append(.dictation(recordingSeconds: recordingSeconds, words: words)) }
        if let rule { events.append(.rule(rule)) }
        record(events)
    }

    func recordToolUse(_ kind: ActivityToolKind) { record([.tool(kind)]) }

    func setRecordingEnabled(_ enabled: Bool) {
        do { snapshot = try writes.sync { [persistence] in try persistence.setRecordingEnabled(enabled) }; loaded = true; issue = nil }
        catch { issue = error.localizedDescription }
    }

    func reset() {
        // An unreadable file must not silently opt a previously opted-out user back in.
        let recordingEnabled = loaded && snapshot.recordingEnabled
        do { snapshot = try writes.sync { [persistence] in try persistence.reset(recordingEnabled: recordingEnabled) }; loaded = true; issue = nil }
        catch { issue = error.localizedDescription }
    }

    private func record(_ events: [ActivityStatisticsEvent]) {
        guard loaded, snapshot.recordingEnabled, !events.isEmpty else { return }
        let date = Date(), timeZone = TimeZone.current
        var counted = snapshot
        do { for event in events { try counted.record(event, at: date, timeZone: timeZone) } }
        catch { issue = error.localizedDescription; return }
        snapshot = counted
        writes.async { [persistence, weak self] in
            // The file is read and merged again, so another running Frog loses nothing.
            do {
                try persistence.record(events, at: date, timeZone: timeZone)
                DispatchQueue.main.async { self?.saved() }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.saveFailed(message) }
            }
        }
    }

    /// Shows what the file holds again, so an event that was not saved is not counted.
    private func saveFailed(_ message: String) {
        reload()
        if loaded { issue = message; issueIsFailedSave = true }
    }

    /// Notices arrive in the order the events were saved, so a later failed save still wins.
    /// A reload, pause or reset that failed after this save keeps its own message.
    private func saved() { if issueIsFailedSave { issue = nil } }
}
