import Foundation

/// Delivery status is finalized after the last suspension point; completed
/// transcripts are recorded separately before delivery begins. A stale recording
/// cannot finalize delivery, even if insertion returns normally after cancellation.
@MainActor
enum DictationDelivery {
    static func finish(isCurrent: () -> Bool, paste: (() async throws -> Void)?,
                       onIssue: (Error) -> Void, onComplete: (String) -> Void) async throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        var delivery = "Copied"
        if let paste {
            do { try await paste(); delivery = "Paste requested · copied" }
            catch {
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                onIssue(error)
            }
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        onComplete(delivery)
    }
}
