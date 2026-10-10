import Foundation

/// Delivery status is finalized after the last suspension point; completed
/// transcripts are recorded separately before delivery begins. A stale recording
/// cannot finalize delivery, even if insertion returns normally after cancellation.
@MainActor
enum DictationDelivery {
    static func finish(isCurrent: () -> Bool, paste: (() async throws -> Void)?,
                       onIssue: (Error) -> Void, onSuccess: () -> Void = {},
                       onComplete: (String) -> Void) async throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        var delivery = "Copied"
        var succeeded = paste == nil
        if let paste {
            do { try await paste(); delivery = "Paste requested · copied"; succeeded = true }
            catch {
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                onIssue(error)
            }
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        if succeeded { onSuccess() }
        // Callbacks may synchronously cancel or start a newer recording.
        guard isCurrent(), !Task.isCancelled else { return }
        onComplete(delivery)
    }
}
