import Foundation

/// Non-streaming text transformations. The supplied session enables deterministic protocol fixtures.
public struct LLMClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func complete(text: String, rule: Rule, provider: ProviderConfiguration, apiKey: String?) async throws -> String {
        try Task.checkCancellation()
        let request = try makeRequest(text: text, rule: rule, provider: provider, apiKey: apiKey)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirects())
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut {
                throw FrogError.message("The provider request timed out. Try again or choose a faster model.")
            }
            // URLSession errors can include the full URL; provider payloads can echo text or keys.
            throw FrogError.message("Could not connect to the provider. Check its endpoint and your network connection.")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw FrogError.message("The provider returned an invalid HTTP response.") }
        guard (200...299).contains(http.statusCode) else { throw statusError(http.statusCode) }
        guard data.count <= 8 * 1_024 * 1_024 else { throw FrogError.message("The provider response was too large.") }
        return try decode(data, kind: provider.kind)
    }

    private func makeRequest(text: String, rule: Rule, provider: ProviderConfiguration, apiKey: String?) throws -> URLRequest {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("Select or enter some text first.") }
        guard text.utf8.count <= 1_000_000 else { throw FrogError.message("The selected text is too large. Process a smaller selection.") }
        let modelOverride = rule.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelOverride.isEmpty ? provider.model.trimmingCharacters(in: .whitespacesAndNewlines) : modelOverride
        guard !model.isEmpty, model.utf8.count <= 256, !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FrogError.message("Choose a valid model in the provider or rule settings.")
        }
        var instructions = rule.instructions
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instructions.utf8.count <= 100_000 else {
            throw FrogError.message("Enter rule instructions of at most 100,000 bytes.")
        }
        if instructions.contains("{{language}}") {
            let language = rule.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !language.isEmpty, language.utf8.count <= 256 else { throw FrogError.message("Choose a target language for this rule.") }
            instructions = instructions.replacingOccurrences(of: "{{language}}", with: language)
        }
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
        let messages: [[String: String]] = [["role": "system", "content": instructions], ["role": "user", "content": text]]
        switch provider.kind {
        case .openAI, .compatible:
            path = "chat/completions"
            body = ["model": model, "messages": messages, "stream": false]
        case .anthropic:
            path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("v1") ? "messages" : "v1/messages"
            body = ["model": model, "system": instructions, "messages": [["role": "user", "content": text]], "max_tokens": 8192, "stream": false]
        case .gemini:
            let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }) else {
                throw FrogError.message("Enter a valid Gemini model name.")
            }
            path = "models/\(name):generateContent"
            body = ["system_instruction": ["parts": [["text": instructions]]],
                    "contents": [["role": "user", "parts": [["text": text]]]]]
        case .ollama:
            path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("api") ? "chat" : "api/chat"
            body = ["model": model, "messages": messages, "stream": false]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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

    private func decode(_ data: Data, kind: ProviderKind) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FrogError.message("The provider returned malformed JSON.")
        }
        var output: String?
        var truncated = false
        switch kind {
        case .openAI, .compatible:
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
}

private final class NoRedirects: NSObject, URLSessionDataDelegate, @unchecked Sendable {
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
