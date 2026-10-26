import Foundation
import FrogAgent

/// Frog's end of the `frog` tool: listens on its socket while agent access is on, and runs
/// each command on the main actor.
@MainActor final class AgentServer: ObservableObject {
    typealias Handler = @MainActor @Sendable (AgentRequest) async -> AgentResponse

    let socket: URL
    private let handler: Handler
    private var listener: AgentListener?
    /// Why the socket could not be opened, for Settings.
    @Published private(set) var issue: String?

    init(socket: URL, handler: @escaping Handler) {
        self.socket = socket
        self.handler = handler
    }

    var isListening: Bool { listener != nil }

    func configure(enabled: Bool) {
        guard enabled else {
            listener?.stop(); listener = nil
            if issue != nil { issue = nil }
            return
        }
        guard listener == nil else { return }
        let handler = handler
        do {
            listener = try AgentListener(socket: socket) { request in await handler(request) }
            if issue != nil { issue = nil }
        } catch {
            issue = "Agents cannot reach Frog: \(error.localizedDescription)"
        }
    }
}
