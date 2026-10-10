import Foundation

/// Synchronous parsers and credential reads run off the UI actor, with their
/// task cancellation linked to the optional module's lifetime.
func usageWork<Value>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    let task = Task.detached(priority: .utility) {
        try Task.checkCancellation()
        return try operation()
    }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
