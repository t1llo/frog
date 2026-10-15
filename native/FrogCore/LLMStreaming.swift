import Foundation

/// One message of a conversation with a model. The instructions travel separately.
public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var text: String
    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// What a streamed answer reports while it is generated.
public enum AnswerEvent: Equatable, Sendable {
    /// A local model is loading; the name to show.
    case loading(String)
    /// Reasoning tokens arrive. Their text is never shown.
    case thinking
    /// Visible text, in order.
    case text(String)
    /// The model stopped at its token limit.
    case truncated
}

/// Turns the lines of one streamed response into answer events: server-sent events for the cloud
/// and OpenAI-style servers, newline-delimited JSON for Ollama. Pure, so every provider's format
/// can be checked without a network. Use one instance per response.
public struct StreamDecoder: Sendable {
    /// More streamed text than this ends the answer with an error.
    public static let textLimit = 8 * 1_024 * 1_024

    private let kind: ProviderKind
    private var event: String?
    private var textBytes = 0
    private var sawText = false
    private var truncated = false
    /// The response said it is complete; later lines are ignored.
    public private(set) var isFinished = false

    public init(kind: ProviderKind) { self.kind = kind }

    public mutating func feed(line: String) throws -> [AnswerEvent] {
        guard !isFinished else { return [] }
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if kind == .ollama {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            return try ollama(Self.object(line))
        }
        if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix(":") { return [] }
        if line.hasPrefix("event:") {
            event = Self.value(line.dropFirst(6))
            return []
        }
        let payload: String
        if line.hasPrefix("data:") { payload = Self.value(line.dropFirst(5)) }
        // Some compatible servers write a bare JSON error into the stream.
        else if line.hasPrefix("{") { payload = line }
        else { return [] }
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            isFinished = true
            return []
        }
        let object = try Self.object(payload)
        switch kind {
        case .openAI, .compatible, .lmStudio: return try openAI(object)
        case .anthropic: return try anthropic(object)
        case .gemini: return try gemini(object)
        case .ollama: return try ollama(object)
        case .claudeCode, .codex, .opencode: throw FrogError.message("Coding tools do not use an HTTP response.")
        }
    }

    public mutating func finish() throws -> [AnswerEvent] {
        guard sawText || truncated else { throw FrogError.message("The provider returned no text. Check the model and try again.") }
        return []
    }

    // MARK: Formats

    private mutating func openAI(_ object: [String: Any]) throws -> [AnswerEvent] {
        if let error = object["error"] { throw Self.providerError(error) }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
        var events: [AnswerEvent] = []
        let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any]
        if let reasoning = delta?["reasoning_content"] as? String ?? delta?["reasoning"] as? String, !reasoning.isEmpty {
            events.append(.thinking)
        }
        if let content = delta?["content"] as? String, !content.isEmpty { events.append(try text(content)) }
        switch choice["finish_reason"] as? String {
        case "length": events.append(markTruncated())
        case "content_filter": throw Self.declined
        default: break
        }
        return events
    }

    private mutating func anthropic(_ object: [String: Any]) throws -> [AnswerEvent] {
        switch object["type"] as? String ?? event {
        case "content_block_start":
            let block = object["content_block"] as? [String: Any]
            switch block?["type"] as? String {
            case "thinking", "redacted_thinking": return [.thinking]
            case "text":
                guard let initial = block?["text"] as? String, !initial.isEmpty else { return [] }
                return [try text(initial)]
            default: return []
            }
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta":
                guard let value = delta?["text"] as? String, !value.isEmpty else { return [] }
                return [try text(value)]
            case "thinking_delta": return [.thinking]
            default: return []
            }
        case "message_delta":
            switch (object["delta"] as? [String: Any])?["stop_reason"] as? String {
            case "max_tokens": return [markTruncated()]
            case "refusal": throw Self.declined
            default: return []
            }
        case "message_stop":
            isFinished = true
            return []
        case "error":
            throw Self.providerError(object["error"] ?? object)
        default:
            // ping, message_start, content_block_stop
            return []
        }
    }

    private mutating func gemini(_ object: [String: Any]) throws -> [AnswerEvent] {
        if let error = object["error"] { throw Self.providerError(error) }
        if (object["promptFeedback"] as? [String: Any])?["blockReason"] != nil { throw Self.declined }
        guard let candidate = (object["candidates"] as? [[String: Any]])?.first else { return [] }
        var events: [AnswerEvent] = []
        for part in (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] {
            guard let value = part["text"] as? String, !value.isEmpty else { continue }
            events.append(part["thought"] as? Bool == true ? .thinking : try text(value))
        }
        switch candidate["finishReason"] as? String {
        case nil, "STOP", "FINISH_REASON_UNSPECIFIED": break
        case "MAX_TOKENS": events.append(markTruncated())
        case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "RECITATION", "SPII", "IMAGE_SAFETY": throw Self.declined
        default: throw Self.stoppedWithError
        }
        return events
    }

    private mutating func ollama(_ object: [String: Any]) throws -> [AnswerEvent] {
        if let error = object["error"] { throw Self.providerError(error) }
        var events: [AnswerEvent] = []
        let message = object["message"] as? [String: Any]
        if let thinking = message?["thinking"] as? String, !thinking.isEmpty { events.append(.thinking) }
        if let content = message?["content"] as? String, !content.isEmpty { events.append(try text(content)) }
        if object["done"] as? Bool == true {
            isFinished = true
            if object["done_reason"] as? String == "length" { events.append(markTruncated()) }
        }
        return events
    }

    // MARK: Helpers

    private mutating func text(_ value: String) throws -> AnswerEvent {
        textBytes += value.utf8.count
        guard textBytes <= Self.textLimit else { throw FrogError.message("The answer was too long.") }
        if !sawText, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sawText = true }
        return .text(value)
    }

    private mutating func markTruncated() -> AnswerEvent {
        truncated = true
        return .truncated
    }

    private static func value(_ field: Substring) -> String {
        String(field.hasPrefix(" ") ? field.dropFirst() : field)
    }

    private static func object(_ payload: String) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            throw FrogError.message("The provider returned malformed JSON.")
        }
        return object
    }

    private static var declined: FrogError { .message("The provider declined to answer this request.") }
    private static var stoppedWithError: FrogError { .message("The provider stopped with an error.") }

    /// Names the kind of failure only: provider messages can echo the request.
    private static func providerError(_ error: Any) -> FrogError {
        let fields = error as? [String: Any] ?? [:]
        let names = [fields["type"], fields["status"], fields["code"]].compactMap { $0 as? String }.map { $0.lowercased() }
        let code = fields["code"] as? Int
        if code == 529 || code == 503 || names.contains(where: { $0.contains("overloaded") || $0 == "unavailable" }) {
            return FrogError.message("The provider is overloaded. Try again shortly.")
        }
        if code == 429 || names.contains(where: { $0.contains("rate_limit") || $0 == "resource_exhausted" }) {
            return FrogError.message("The provider's rate limit was reached.")
        }
        return stoppedWithError
    }
}
