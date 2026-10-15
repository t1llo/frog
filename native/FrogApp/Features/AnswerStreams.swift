import Foundation
import FrogCore

/// One answer turn as it goes to a model: the resolved provider and exactly what it receives.
struct AnswerRequest: Sendable {
    var rule: Rule
    var provider: ProviderConfiguration
    var apiKey: String?
    var instructions: String
    var messages: [ChatMessage]
    /// A model Frog runs itself (`AppModel.localProviderID`).
    var isFrogLocal: Bool
}

/// Where an answer's events come from: Frog's own models, a coding tool, or an HTTP provider.
enum AnswerStreams {
    /// Coding tools answer in one piece and may think for a while before they do.
    static let codingToolTimeout: TimeInterval = 180

    /// The real backends.
    @MainActor static func live(localModels: LocalModels, localTools: LocalToolClient) -> (AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        { request in
            if request.isFrogLocal {
                return localModels.stream(messages: request.messages, instructions: request.instructions, modelID: request.provider.model)
            }
            if let kind = request.provider.kind.localTool {
                return codingTool(request, kind: kind) { try await localTools.complete($0, timeout: codingToolTimeout) }
            }
            return LLMClient().stream(messages: request.messages, instructions: request.instructions, rule: request.rule,
                                      provider: request.provider, apiKey: request.apiKey)
        }
    }

    /// A coding tool takes one prompt, so it gets the conversation as a transcript and its whole
    /// answer arrives as one text event.
    static func codingTool(_ request: AnswerRequest, kind: LocalToolKind,
                           complete: @escaping @Sendable (LocalToolRequest) async throws -> String) -> AsyncThrowingStream<AnswerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = request.provider.model == LocalToolKind.defaultModelID ? "" : request.provider.model
                    let tool = try LocalToolRequest(kind: kind, model: model, instructions: request.instructions,
                                                    text: AnswerPrompt.transcript(request.messages))
                    let answer = try await complete(tool)
                    try Task.checkCancellation()
                    continuation.yield(.text(answer))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
