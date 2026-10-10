import Combine
import Foundation
import FrogCore

/// Completion hooks stay synchronous and ordered. A statistics failure never fails a tool action.
@MainActor final class ActivityStatisticsStore: ObservableObject {
    @Published private(set) var snapshot = ActivityStatisticsSnapshot()
    @Published private(set) var issue: String?
    @Published private(set) var loaded = false
    private let persistence: ActivityStatisticsPersistence

    init(directory: URL? = nil) {
        persistence = ActivityStatisticsPersistence(directory: directory)
        reload()
    }

    func reload() {
        do { snapshot = try persistence.load(); loaded = true; issue = nil }
        catch { loaded = false; issue = error.localizedDescription }
    }

    func recordRuleExecution(kind: ActivityRuleKind) { record(.rule(kind)) }

    /// Supply microphone capture time only, excluding model loading/transcription/insertion.
    /// Invoke only after a nonempty successful delivery, including intentional copy-only delivery.
    func recordDictation(recordingSeconds: Double, text: String) {
        guard loaded, snapshot.recordingEnabled else { return }
        let words = ActivityStatisticsSnapshot.wordCount(in: text)
        guard recordingSeconds.isFinite, recordingSeconds > 0, words > 0 else { return }
        record(.dictation(recordingSeconds: recordingSeconds, words: words))
    }

    func recordToolUse(_ kind: ActivityToolKind) { record(.tool(kind)) }

    func setRecordingEnabled(_ enabled: Bool) {
        do { snapshot = try persistence.setRecordingEnabled(enabled); loaded = true; issue = nil }
        catch { issue = error.localizedDescription }
    }

    func reset() {
        // An unreadable file must not silently opt a previously opted-out user back in.
        do { snapshot = try persistence.reset(recordingEnabled: loaded && snapshot.recordingEnabled); loaded = true; issue = nil }
        catch { issue = error.localizedDescription }
    }

    private func record(_ event: ActivityStatisticsEvent) {
        guard loaded, snapshot.recordingEnabled else { return }
        do { snapshot = try persistence.record(event); issue = nil }
        catch { issue = error.localizedDescription }
    }
}
