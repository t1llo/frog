import Foundation

/// Text transformations and streamed answers. The supplied session enables deterministic protocol fixtures.
public struct LLMClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func complete(text: String, rule: Rule, provider: ProviderConfiguration, apiKey: String?) async throws -> String {
        try Task.checkCancellation()
        guard provider.kind.localTool == nil else { throw FrogError.message("Use the installed coding-tool client for this provider.") }
        let request = try makeRequest(messages: [ChatMessage(role: .user, text: text)], instructions: Self.ruleInstructions(rule),
                                      rule: rule, provider: provider, apiKey: apiKey, stream: false, maxTokens: nil)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirects())
        } catch { throw Self.transportError(error) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw FrogError.message("The provider returned an invalid HTTP response.") }
        guard (200...299).contains(http.statusCode) else { throw statusError(http.statusCode) }
        guard data.count <= 8 * 1_024 * 1_024 else { throw FrogError.message("The provider response was too large.") }
        return try decode(data, kind: provider.kind)
    }

    /// Streams an answer to a conversation as it is generated. The rule contributes only its model
    /// override; the instructions are sent as the system prompt. Cancelling the consumer cancels the request.
    public func stream(messages: [ChatMessage], instructions: String, rule: Rule, provider: ProviderConfiguration,
                       apiKey: String?, maxTokens: Int = 4_096) -> AsyncThrowingStream<AnswerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamAnswer(messages: messages, instructions: instructions, rule: rule, provider: provider,
                                           apiKey: apiKey, maxTokens: maxTokens) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamAnswer(messages: [ChatMessage], instructions: String, rule: Rule, provider: ProviderConfiguration,
                              apiKey: String?, maxTokens: Int, yield: (AnswerEvent) -> Void) async throws {
        try Task.checkCancellation()
        guard provider.kind.localTool == nil else { throw FrogError.message("Coding tools do not use an HTTP endpoint.") }
        let request = try makeRequest(messages: messages, instructions: Self.checkedInstructions(instructions), rule: rule,
                                      provider: provider, apiKey: apiKey, stream: true, maxTokens: maxTokens)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
        } catch { throw Self.transportError(error) }
        // Ends the connection when the answer is complete, fails or is cancelled before the server closes it.
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw FrogError.message("The provider returned an invalid HTTP response.") }
        guard (200...299).contains(http.statusCode) else { throw statusError(http.statusCode) }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        var decoder = StreamDecoder(kind: provider.kind)
        do {
            if type.contains("text/event-stream") || type.contains("application/x-ndjson") {
                for try await line in bytes.lines {
                    for event in try decoder.feed(line: line) { yield(event) }
                    if decoder.isFinished { break }
                }
            } else {
                // A compatible server that ignores "stream" answers in one piece.
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    guard data.count <= StreamDecoder.textLimit else { throw FrogError.message("The answer was too long.") }
                }
                try Task.checkCancellation()
                let body = String(decoding: data, as: UTF8.self)
                if body.drop(while: { $0.isWhitespace }).hasPrefix("data:") {
                    for line in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
                        for event in try decoder.feed(line: String(line)) { yield(event) }
                    }
                } else {
                    yield(.text(try decode(data, kind: provider.kind)))
                    return
                }
            }
        } catch let error as FrogError { throw error }
        catch { throw Self.transportError(error) }
        try Task.checkCancellation()
        for event in try decoder.finish() { yield(event) }
    }

    /// URLSession errors can include the full URL; provider payloads can echo text or keys.
    private static func transportError(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if (error as? URLError)?.code == .timedOut {
            return FrogError.message("The provider request timed out. Try again or choose a faster model.")
        }
        return FrogError.message("Could not connect to the provider. Check its endpoint and your network connection.")
    }

    private static func ruleInstructions(_ rule: Rule) throws -> String {
        guard !rule.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.instructions.utf8.count <= 100_000 else {
            throw FrogError.message("Enter rule instructions of at most 100,000 bytes.")
        }
        return try rule.expandedInstructions()
    }

    private static func checkedInstructions(_ instructions: String) throws -> String {
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instructions.utf8.count <= 100_000 else {
            throw FrogError.message("Enter rule instructions of at most 100,000 bytes.")
        }
        return instructions
    }

    /// Builds the request for one answer. `instructions` is evaluated after the text and model checks,
    /// so the first problem found is reported in the same order for every request.
    private func makeRequest(messages: [ChatMessage], instructions: @autoclosure () throws -> String, rule: Rule,
                             provider: ProviderConfiguration, apiKey: String?, stream: Bool, maxTokens: Int?) throws -> URLRequest {
        guard !messages.isEmpty, messages.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw FrogError.message("Select or enter some text first.")
        }
        guard messages.reduce(0, { $0 + $1.text.utf8.count }) <= 1_000_000 else {
            throw FrogError.message("The selected text is too large. Process a smaller selection.")
        }
        let modelOverride = rule.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelOverride.isEmpty ? provider.model.trimmingCharacters(in: .whitespacesAndNewlines) : modelOverride
        guard !model.isEmpty, model.utf8.count <= 256, !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FrogError.message("Choose a valid model in the provider or rule settings.")
        }
        let instructions = try instructions()
        guard let base = URLComponents(string: provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = base.host, !host.isEmpty, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, let baseURL = base.url else {
            throw FrogError.message("Enter an HTTP or HTTPS provider base URL without credentials, a query, or a fragment.")
        }
        if [.openAI, .anthropic, .gemini].contains(provider.kind), scheme != "https" {
            throw FrogError.message("Cloud providers require an HTTPS endpoint.")
        }
        let key: String?
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            key = try KeychainStore.validatedKey(apiKey)
        } else { key = nil }
        if [.openAI, .anthropic, .gemini].contains(provider.kind), key == nil {
            throw FrogError.message("Add an API key for this provider in Providers.")
        }
        let path: String
        let body: [String: Any]
        let conversation: [[String: String]] = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let messages: [[String: String]] = [["role": "system", "content": instructions]] + conversation
        switch provider.kind {
        case .openAI, .compatible, .lmStudio:
            path = "chat/completions"
            body = ["model": model, "messages": messages, "stream": stream]
        case .anthropic:
            path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("v1") ? "messages" : "v1/messages"
            // The limit covers the model's thinking as well as the text. A request that does not
            // stream should not ask for more: the whole answer has to arrive within the timeout.
            body = ["model": model, "system": instructions, "messages": conversation, "max_tokens": maxTokens ?? 16_000, "stream": stream]
        case .gemini:
            let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }) else {
                throw FrogError.message("Enter a valid Gemini model name.")
            }
            path = "models/\(name):\(stream ? "streamGenerateContent" : "generateContent")"
            body = ["system_instruction": ["parts": [["text": instructions]]],
                    "contents": conversation.map { ["role": $0["role"] == "assistant" ? "model" : "user", "parts": [["text": $0["content"] ?? ""]]] }]
        case .ollama:
            path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("api") ? "chat" : "api/chat"
            body = ["model": model, "messages": messages, "stream": stream]
        case .claudeCode, .codex, .opencode:
            throw FrogError.message("Coding tools do not use an HTTP endpoint.")
        }
        var url = baseURL.appendingPathComponent(path)
        if stream, provider.kind == .gemini {
            // Without alt=sse Gemini streams one JSON array instead of server-sent events.
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw FrogError.message("Enter a valid Gemini model name.")
            }
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            guard let streamURL = components.url else { throw FrogError.message("Enter a valid Gemini model name.") }
            url = streamURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.timeout(for: provider.kind))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let accept = !stream ? "application/json" : provider.kind == .ollama ? "application/x-ndjson" : "text/event-stream"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let key {
            switch provider.kind {
            case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key")
            case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            default: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        if provider.kind == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The timeout counts silence, and a non-streaming answer is silent until it is complete: it has
    /// to cover the whole generation and, on a server that loads models on demand, the load before it.
    /// Claude's 16,000 tokens are sized for the ten minutes Anthropic's own clients wait.
    /// The request stays cancellable throughout.
    private static func timeout(for kind: ProviderKind) -> TimeInterval {
        switch kind {
        case .ollama, .lmStudio, .compatible, .anthropic: return 600
        default: return 300
        }
    }

    private func decode(_ data: Data, kind: ProviderKind) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FrogError.message("The provider returned malformed JSON.")
        }
        var output: String?
        var truncated = false
        switch kind {
        case .openAI, .compatible, .lmStudio:
            let choice = (object["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            output = message?["content"] as? String
            truncated = choice?["finish_reason"] as? String == "length"
            if choice?["finish_reason"] as? String == "content_filter" { throw FrogError.message("The provider declined to return text for this request.") }
        case .anthropic:
            output = (object["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
            truncated = object["stop_reason"] as? String == "max_tokens"
        case .gemini:
            let candidate = (object["candidates"] as? [[String: Any]])?.first
            let content = candidate?["content"] as? [String: Any]
            output = (content?["parts"] as? [[String: Any]])?.filter { $0["thought"] as? Bool != true }
                .compactMap { $0["text"] as? String }.joined()
            let reason = candidate?["finishReason"] as? String
            truncated = reason == "MAX_TOKENS"
            if let reason, !["STOP", "MAX_TOKENS"].contains(reason) { throw FrogError.message("The provider declined to return complete text for this request.") }
        case .ollama:
            output = (object["message"] as? [String: Any])?["content"] as? String
            truncated = object["done"] as? Bool == false || object["done_reason"] as? String == "length"
        case .claudeCode, .codex, .opencode:
            throw FrogError.message("Coding tools do not use an HTTP response.")
        }
        guard !truncated else { throw FrogError.message("The provider stopped before completing the text. Try a smaller selection.") }
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FrogError.message("The provider returned no text. Check the model and try again.")
        }
        // Preserve intentional indentation and trailing newlines for replacement.
        return output
    }

    private func statusError(_ status: Int) -> FrogError {
        switch status {
        case 300...399: return .message("The provider redirected the request. Update its base URL to the final endpoint.")
        case 401, 403: return .message("The provider rejected authentication. Check the API key and model access.")
        case 404: return .message("The provider endpoint or model was not found. Check the base URL and model name.")
        case 408, 504: return .message("The provider request timed out. Try again later.")
        case 429: return .message("The provider rate limit or quota was reached. Check your usage and try again later.")
        case 500...599: return .message("The provider is temporarily unavailable (HTTP \(status)). Try again later.")
        default: return .message("The provider rejected the request (HTTP \(status)). Check the model and provider settings.")
        }
    }

    /// Discover installed models only when explicitly requested; never sends writing text.
    public func localModels(provider: ProviderConfiguration, apiKey: String?) async throws -> [ProviderModel] {
        guard provider.kind.isLocal else { throw FrogError.message("Model discovery is available for Ollama and LM Studio.") }
        try ConfigurationFile.validateEndpoint(provider)
        let base = URL(string: provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))!
        let path = provider.kind == .ollama
            ? (base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("api") ? "tags" : "api/tags")
            : "models"
        var request = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(try KeychainStore.validatedKey(apiKey))", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: NoRedirects()) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw FrogError.message("Could not reach the local server. Start \(provider.kind.title), enable its server, and check the endpoint.")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw FrogError.message("The model server returned an invalid response.") }
        guard (200...299).contains(http.statusCode) else { throw statusError(http.statusCode) }
        guard data.count <= 8 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object[provider.kind == .ollama ? "models" : "data"] as? [[String: Any]] else {
            throw FrogError.message("The model server returned an invalid model list.")
        }
        let names = entries.compactMap { $0[provider.kind == .ollama ? "name" : "id"] as? String }
        return Set(names).filter { !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
            .sorted().prefix(200).map { ProviderModel(id: $0) }
    }

    /// Checks the endpoint and key of a speech service by asking for its model list. A connection
    /// with only speech models has no text model to try, and the request carries no text or audio.
    public func checkConnection(provider: ProviderConfiguration, apiKey: String?) async throws {
        guard provider.kind.supportsTranscription else { throw FrogError.message("This service does not support speech-to-text.") }
        try ConfigurationFile.validateEndpoint(provider)
        let key: String?
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            key = try KeychainStore.validatedKey(apiKey)
        } else { key = nil }
        if [.openAI, .gemini].contains(provider.kind), key == nil {
            throw FrogError.message("Add an API key for this provider in Providers.")
        }
        let base = URL(string: provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))!
        var request = URLRequest(url: base.appendingPathComponent("models"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        if let key {
            if provider.kind == .gemini { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
            else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        let response: URLResponse
        do { (_, response) = try await session.data(for: request, delegate: NoRedirects()) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw FrogError.message("Could not connect to the provider. Check its endpoint and your network connection.")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw FrogError.message("The provider returned an invalid HTTP response.") }
        guard (200...299).contains(http.statusCode) else { throw statusError(http.statusCode) }
    }
}

private final class NoRedirects: NSObject, URLSessionDataDelegate, Sendable {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Redirects must not forward credentials or selected text to a different endpoint.
        completionHandler(nil)
    }
}
