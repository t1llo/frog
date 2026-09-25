import Foundation

/// Completion is an atomic UI/history callback after the last suspension point.
/// A stale recording can never finalize, even if an insertion implementation
/// returns normally after cancellation.
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
