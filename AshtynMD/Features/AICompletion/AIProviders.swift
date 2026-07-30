import Foundation

/// Reads a byte stream into lines, preserving empty lines (SSE needs the
/// blank delimiter lines that higher-level line sequences may drop).
private struct ByteLineAccumulator {
    private var buffer = Data()

    mutating func append(_ byte: UInt8) -> String? {
        if byte == 0x0A {
            let line = String(data: buffer, encoding: .utf8) ?? ""
            buffer.removeAll(keepingCapacity: true)
            return line
        }
        buffer.append(byte)
        return nil
    }

    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let line = String(data: buffer, encoding: .utf8) ?? ""
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

/// Shared streaming loop: runs the request, checks the status, hands each
/// line to `handleLine`, which returns deltas to emit and/or a final usage.
private func streamLines(
    request: URLRequest,
    into continuation: AsyncThrowingStream<AICompletionEvent, Error>.Continuation,
    maximumOutputCharacters: Int,
    handleLine: @escaping @Sendable (String, inout Bool) throws -> [StreamAction]
) -> Task<Void, Never> {
    Task {
        var emitted = 0
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIProviderError.invalidResponse("Not an HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await line in bytes.lines {
                    body += line + "\n"
                    if body.count > 4096 { break }
                }
                throw ProviderHTTP.errorForResponse(http, bodyText: body)
            }

            var accumulator = ByteLineAccumulator()
            var finished = false
            var usage: AIUsage?

            func process(_ line: String) throws {
                var done = false
                for action in try handleLine(line, &done) {
                    switch action {
                    case .delta(let text):
                        guard !text.isEmpty, emitted < maximumOutputCharacters else { break }
                        let remaining = maximumOutputCharacters - emitted
                        let clipped = String(text.prefix(remaining))
                        emitted += clipped.count
                        continuation.yield(.textDelta(clipped))
                        if emitted >= maximumOutputCharacters { done = true }
                    case .usage(let u):
                        usage = u
                    }
                }
                if done { finished = true }
            }

            for try await byte in bytes {
                try Task.checkCancellation()
                if let line = accumulator.append(byte) {
                    try process(line)
                    if finished { break }
                }
            }
            if !finished, let tail = accumulator.flush() {
                try process(tail)
            }
            continuation.yield(.completed(usage))
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch let error as URLError where error.code == .cancelled {
            continuation.finish(throwing: CancellationError())
        } catch let error as AIProviderError {
            continuation.finish(throwing: error)
        } catch {
            continuation.finish(throwing: AIProviderError.network(error.localizedDescription))
        }
    }
}

enum StreamAction {
    case delta(String)
    case usage(AIUsage)
}

/// Box so the serially-invoked line handler can hold decoder state inside a
/// @Sendable closure. Only one task ever touches it.
private final class SSEDecoderBox: @unchecked Sendable {
    var decoder = SSEDecoder()
}

// MARK: - OpenAI (Responses API)

struct OpenAIProvider: AICompletionProvider {
    let id: AIProviderID = .openAI
    let apiKey: String
    let model: String
    var baseURL = URL(string: "https://api.openai.com/v1")!

    func availableModels() async throws -> [AIModel] {
        let request = try ProviderHTTP.jsonRequest(
            url: baseURL.appendingPathComponent("models"),
            method: "GET",
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: nil
        )
        let object = try await fetchJSON(request)
        guard let data = object["data"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse("Missing model list")
        }
        return data.compactMap { entry in
            (entry["id"] as? String).map { AIModel(id: $0, displayName: $0) }
        }.sorted { $0.id < $1.id }
    }

    func validateConfiguration() async throws {
        guard !apiKey.isEmpty else {
            throw AIProviderError.notConfigured("Add an OpenAI API key first.")
        }
        _ = try await availableModels()
    }

    func complete(_ request: AICompletionRequest) -> AsyncThrowingStream<AICompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !apiKey.isEmpty, !model.isEmpty else {
                continuation.finish(throwing: AIProviderError.notConfigured(
                    "Configure an OpenAI API key and model in Settings."
                ))
                return
            }
            let body: [String: Any] = [
                "model": model,
                "instructions": AIPrompt.systemInstruction,
                "input": AIPrompt.userContent(for: request),
                "stream": true,
                "store": false,
            ]
            let urlRequest: URLRequest
            do {
                urlRequest = try ProviderHTTP.jsonRequest(
                    url: baseURL.appendingPathComponent("responses"),
                    headers: ["Authorization": "Bearer \(apiKey)"],
                    body: body
                )
            } catch {
                continuation.finish(throwing: AIProviderError.network(error.localizedDescription))
                return
            }

            let box = SSEDecoderBox()
            let task = streamLines(
                request: urlRequest,
                into: continuation,
                maximumOutputCharacters: request.maximumOutputCharacters
            ) { line, done in
                guard let event = box.decoder.feed(line: line) else { return [] }
                return Self.actions(forEventData: event.data, done: &done)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func actions(forEventData data: String, done: inout Bool) -> [StreamAction] {
        if data == "[DONE]" {
            done = true
            return []
        }
        guard let json = NDJSONDecoder.object(fromLine: data),
              let type = json["type"] as? String else { return [] }
        switch type {
        case "response.output_text.delta":
            return (json["delta"] as? String).map { [.delta($0)] } ?? []
        case "response.completed":
            done = true
            if let response = json["response"] as? [String: Any],
               let usage = response["usage"] as? [String: Any] {
                return [.usage(AIUsage(
                    inputTokens: usage["input_tokens"] as? Int,
                    outputTokens: usage["output_tokens"] as? Int
                ))]
            }
            return []
        case "response.failed", "error":
            done = true
            return []
        default:
            // Unknown future event types are ignored by design.
            return []
        }
    }
}

// MARK: - Anthropic (Messages API)

struct AnthropicProvider: AICompletionProvider {
    let id: AIProviderID = .anthropic
    let apiKey: String
    let model: String
    var baseURL = URL(string: "https://api.anthropic.com/v1")!

    private var headers: [String: String] {
        [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
    }

    func availableModels() async throws -> [AIModel] {
        let request = try ProviderHTTP.jsonRequest(
            url: baseURL.appendingPathComponent("models"),
            method: "GET",
            headers: headers,
            body: nil
        )
        let object = try await fetchJSON(request)
        guard let data = object["data"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse("Missing model list")
        }
        return data.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return AIModel(id: id, displayName: entry["display_name"] as? String ?? id)
        }
    }

    func validateConfiguration() async throws {
        guard !apiKey.isEmpty else {
            throw AIProviderError.notConfigured("Add an Anthropic API key first.")
        }
        _ = try await availableModels()
    }

    func complete(_ request: AICompletionRequest) -> AsyncThrowingStream<AICompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !apiKey.isEmpty, !model.isEmpty else {
                continuation.finish(throwing: AIProviderError.notConfigured(
                    "Configure an Anthropic API key and model in Settings."
                ))
                return
            }
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 1024,
                "system": AIPrompt.systemInstruction,
                "messages": [["role": "user", "content": AIPrompt.userContent(for: request)]],
                "stream": true,
            ]
            let urlRequest: URLRequest
            do {
                urlRequest = try ProviderHTTP.jsonRequest(
                    url: baseURL.appendingPathComponent("messages"),
                    headers: headers,
                    body: body
                )
            } catch {
                continuation.finish(throwing: AIProviderError.network(error.localizedDescription))
                return
            }

            let box = SSEDecoderBox()
            let task = streamLines(
                request: urlRequest,
                into: continuation,
                maximumOutputCharacters: request.maximumOutputCharacters
            ) { line, done in
                guard let event = box.decoder.feed(line: line) else { return [] }
                return try Self.actions(forEvent: event, done: &done)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func actions(forEvent event: SSEDecoder.Event, done: inout Bool) throws -> [StreamAction] {
        guard let json = NDJSONDecoder.object(fromLine: event.data) else { return [] }
        let type = (json["type"] as? String) ?? event.name ?? ""
        switch type {
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return [] }
            return [.delta(text)]
        case "message_delta":
            if let usage = json["usage"] as? [String: Any] {
                return [.usage(AIUsage(
                    inputTokens: usage["input_tokens"] as? Int,
                    outputTokens: usage["output_tokens"] as? Int
                ))]
            }
            return []
        case "message_stop":
            done = true
            return []
        case "error":
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
            throw AIProviderError.invalidResponse(message)
        default:
            // ping, message_start, content_block_start/stop, unknown futures.
            return []
        }
    }
}

// MARK: - Ollama (native chat endpoint)

struct OllamaProvider: AICompletionProvider {
    let id: AIProviderID = .ollama
    let model: String
    var baseURL = OllamaProvider.defaultBaseURL

    static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    func availableModels() async throws -> [AIModel] {
        let request = try ProviderHTTP.jsonRequest(
            url: baseURL.appendingPathComponent("api/tags"),
            method: "GET",
            headers: [:],
            body: nil
        )
        let object = try await fetchJSON(request)
        guard let models = object["models"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse("Missing model list")
        }
        return models.compactMap { entry in
            (entry["name"] as? String).map { AIModel(id: $0, displayName: $0) }
        }
    }

    func validateConfiguration() async throws {
        _ = try await availableModels()
    }

    func complete(_ request: AICompletionRequest) -> AsyncThrowingStream<AICompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !model.isEmpty else {
                continuation.finish(throwing: AIProviderError.notConfigured(
                    "Choose an Ollama model in Settings."
                ))
                return
            }
            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": AIPrompt.systemInstruction],
                    ["role": "user", "content": AIPrompt.userContent(for: request)],
                ],
                "stream": true,
            ]
            let urlRequest: URLRequest
            do {
                urlRequest = try ProviderHTTP.jsonRequest(
                    url: baseURL.appendingPathComponent("api/chat"),
                    headers: [:],
                    body: body
                )
            } catch {
                continuation.finish(throwing: AIProviderError.network(error.localizedDescription))
                return
            }

            let task = streamLines(
                request: urlRequest,
                into: continuation,
                maximumOutputCharacters: request.maximumOutputCharacters
            ) { line, done in
                try Self.actions(forLine: line, done: &done)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func actions(forLine line: String, done: inout Bool) throws -> [StreamAction] {
        guard let json = NDJSONDecoder.object(fromLine: line) else { return [] }
        if let error = json["error"] as? String {
            throw AIProviderError.invalidResponse(error)
        }
        var actions: [StreamAction] = []
        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            actions.append(.delta(content))
        }
        if json["done"] as? Bool == true {
            done = true
            actions.append(.usage(AIUsage(
                inputTokens: json["prompt_eval_count"] as? Int,
                outputTokens: json["eval_count"] as? Int
            )))
        }
        return actions
    }
}

// MARK: - Shared JSON fetch

private func fetchJSON(_ request: URLRequest) async throws -> [String: Any] {
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        throw AIProviderError.network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
        throw AIProviderError.invalidResponse("Not an HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
        throw ProviderHTTP.errorForResponse(
            http, bodyText: String(data: data.prefix(4096), encoding: .utf8) ?? ""
        )
    }
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw AIProviderError.invalidResponse("Expected a JSON object")
    }
    return object
}
