import Foundation
import Testing
@testable import AshtynMD

@Suite("SSE decoding")
struct SSEDecoderTests {
    private func events(fromLines lines: [String]) -> [SSEDecoder.Event] {
        var decoder = SSEDecoder()
        var results: [SSEDecoder.Event] = []
        for line in lines {
            if let event = decoder.feed(line: line) { results.append(event) }
        }
        if let tail = decoder.flush() { results.append(tail) }
        return results
    }

    @Test func basicEventWithName() {
        let result = events(fromLines: [
            "event: message_start",
            "data: {\"a\":1}",
            "",
        ])
        #expect(result == [SSEDecoder.Event(name: "message_start", data: "{\"a\":1}")])
    }

    @Test func multiLineDataIsJoined() {
        let result = events(fromLines: [
            "data: first",
            "data: second",
            "",
        ])
        #expect(result.first?.data == "first\nsecond")
    }

    @Test func commentsAndUnknownFieldsAreIgnored() {
        let result = events(fromLines: [
            ": keep-alive",
            "id: 42",
            "retry: 100",
            "data: payload",
            "",
        ])
        #expect(result == [SSEDecoder.Event(name: nil, data: "payload")])
    }

    @Test func carriageReturnsAreStripped() {
        let result = events(fromLines: ["data: hi\r", "\r"])
        #expect(result.first?.data == "hi")
    }

    @Test func unterminatedEventIsFlushed() {
        let result = events(fromLines: ["data: tail"])
        #expect(result == [SSEDecoder.Event(name: nil, data: "tail")])
    }

    @Test func multipleEventsInSequence() {
        let result = events(fromLines: [
            "data: one", "",
            "data: two", "",
        ])
        #expect(result.map(\.data) == ["one", "two"])
    }
}

@Suite("Provider event mapping")
struct ProviderEventTests {
    @Test func openAIDeltaAndCompletion() {
        var done = false
        let delta = OpenAIProvider.actions(
            forEventData: #"{"type":"response.output_text.delta","delta":"let x"}"#, done: &done
        )
        #expect(!done)
        if case .delta(let text)? = delta.first {
            #expect(text == "let x")
        } else {
            Issue.record("expected delta")
        }

        let completed = OpenAIProvider.actions(
            forEventData: #"{"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":5}}}"#,
            done: &done
        )
        #expect(done)
        if case .usage(let usage)? = completed.first {
            #expect(usage == AIUsage(inputTokens: 10, outputTokens: 5))
        } else {
            Issue.record("expected usage")
        }
    }

    @Test func openAIUnknownEventsAndDoneMarker() {
        var done = false
        #expect(OpenAIProvider.actions(
            forEventData: #"{"type":"response.some_future_event"}"#, done: &done
        ).isEmpty)
        #expect(!done)
        _ = OpenAIProvider.actions(forEventData: "[DONE]", done: &done)
        #expect(done)
    }

    @Test func anthropicTextDeltaAndStop() throws {
        var done = false
        let delta = try AnthropicProvider.actions(
            forEvent: SSEDecoder.Event(
                name: "content_block_delta",
                data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}"#
            ),
            done: &done
        )
        if case .delta(let text)? = delta.first {
            #expect(text == "hello")
        } else {
            Issue.record("expected delta")
        }

        _ = try AnthropicProvider.actions(
            forEvent: SSEDecoder.Event(name: "message_stop", data: #"{"type":"message_stop"}"#),
            done: &done
        )
        #expect(done)
    }

    @Test func anthropicPingAndUnknownAreIgnoredErrorThrows() throws {
        var done = false
        #expect(try AnthropicProvider.actions(
            forEvent: SSEDecoder.Event(name: "ping", data: #"{"type":"ping"}"#), done: &done
        ).isEmpty)
        #expect(try AnthropicProvider.actions(
            forEvent: SSEDecoder.Event(name: "future_thing", data: #"{"type":"future_thing"}"#), done: &done
        ).isEmpty)
        #expect(throws: AIProviderError.self) {
            _ = try AnthropicProvider.actions(
                forEvent: SSEDecoder.Event(
                    name: "error",
                    data: #"{"type":"error","error":{"message":"overloaded"}}"#
                ),
                done: &done
            )
        }
    }

    @Test func ollamaContentAndDone() throws {
        var done = false
        let delta = try OllamaProvider.actions(
            forLine: #"{"message":{"content":"chunk"},"done":false}"#, done: &done
        )
        if case .delta(let text)? = delta.first {
            #expect(text == "chunk")
        } else {
            Issue.record("expected delta")
        }
        #expect(!done)

        let final = try OllamaProvider.actions(
            forLine: #"{"message":{"content":""},"done":true,"prompt_eval_count":8,"eval_count":3}"#,
            done: &done
        )
        #expect(done)
        if case .usage(let usage)? = final.first {
            #expect(usage == AIUsage(inputTokens: 8, outputTokens: 3))
        } else {
            Issue.record("expected usage")
        }
    }

    @Test func ollamaErrorLineThrows() {
        var done = false
        #expect(throws: AIProviderError.self) {
            _ = try OllamaProvider.actions(forLine: #"{"error":"model not found"}"#, done: &done)
        }
    }
}

@Suite("Completion context")
struct CompletionContextTests {
    @Test func smallDocumentHasNoHead() {
        let text = "func main() {}\n"
        let request = CompletionContext.request(
            text: text, caretLocation: 5, language: .swift,
            fileName: "main.swift", trigger: .manual
        )
        #expect(request.prefix == "func ")
        #expect(request.suffix == "main() {}\n")
        #expect(request.documentHead == nil)
        #expect(request.maximumOutputCharacters == 4000)
    }

    @Test func windowsAreCappedAndHeadAppears() {
        let filler = String(repeating: "a", count: 30_000)
        let text = "// IMPORTS\n" + filler
        let caret = (text as NSString).length
        let request = CompletionContext.request(
            text: text, caretLocation: caret, language: .swift,
            fileName: "big.swift", trigger: .automatic
        )
        #expect(request.prefix.count == CompletionContext.maximumPrefix)
        #expect(request.suffix.isEmpty)
        #expect(request.documentHead?.hasPrefix("// IMPORTS") == true)
        #expect((request.documentHead?.count ?? 0) <= CompletionContext.maximumDocumentHead)
    }

    @Test func emojiBoundariesAreNotSplit() {
        // A caret window edge landing inside a surrogate pair must snap.
        let text = String(repeating: "🙂", count: 10_000) // 20k UTF-16 units
        let caret = 17_001 // odd → inside a pair without snapping
        let request = CompletionContext.request(
            text: text, caretLocation: caret, language: .plainText,
            fileName: "emoji.txt", trigger: .manual
        )
        // No replacement characters appear when boundaries are respected.
        #expect(!request.prefix.contains("\u{FFFD}"))
        #expect(!request.suffix.contains("\u{FFFD}"))
    }

    @Test func promptContainsOnlyCurrentFileSections() {
        let request = CompletionContext.request(
            text: "hello world", caretLocation: 5, language: .markdown,
            fileName: "note.md", trigger: .manual
        )
        let content = AIPrompt.userContent(for: request)
        #expect(content.contains("File: note.md"))
        #expect(content.contains("Language: Markdown"))
        #expect(content.contains("Text before cursor:\nhello"))
        #expect(content.contains("Text after cursor:\n world"))
    }
}

// MARK: - Mock provider

/// Scripted provider used to drive the controller without networking.
struct MockProvider: AICompletionProvider {
    let id: AIProviderID = .ollama
    enum Behavior: Sendable {
        case stream([String], delayMilliseconds: Int)
        case fail(AIProviderError)
    }
    let behavior: Behavior

    func availableModels() async throws -> [AIModel] {
        [AIModel(id: "mock", displayName: "Mock")]
    }

    func validateConfiguration() async throws {}

    func complete(_ request: AICompletionRequest) -> AsyncThrowingStream<AICompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch behavior {
                case .stream(let chunks, let delay):
                    for chunk in chunks {
                        try? await Task.sleep(for: .milliseconds(delay))
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        continuation.yield(.textDelta(chunk))
                    }
                    continuation.yield(.completed(nil))
                    continuation.finish()
                case .fail(let error):
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("AI completion controller", .serialized)
@MainActor
struct AICompletionControllerTests {
    private func makeController(_ behavior: MockProvider.Behavior) -> AICompletionController {
        let controller = AICompletionController()
        controller.providerFactory = { MockProvider(behavior: behavior) }
        return controller
    }

    private func request() -> AICompletionRequest {
        CompletionContext.request(
            text: "let x = ", caretLocation: 8, language: .swift,
            fileName: "t.swift", trigger: .manual
        )
    }

    @Test func nilContextDoesNotConstructAProvider() {
        let controller = AICompletionController()
        var providerWasRequested = false
        controller.providerFactory = {
            providerWasRequested = true
            return MockProvider(
                behavior: .stream(["unused"], delayMilliseconds: 0)
            )
        }

        controller.requestManually { nil }

        #expect(!providerWasRequested)
        #expect(controller.ghostText == nil)
    }

    @Test func streamedGhostTextAccumulatesAndAcceptClears() async throws {
        let controller = makeController(.stream(["let ", "y = 2"], delayMilliseconds: 10))
        var updates: [String?] = []
        controller.onGhostTextChange = { updates.append($0) }

        controller.requestManually { [request = request()] in request }
        try await Task.sleep(for: .milliseconds(300))

        #expect(controller.ghostText == "let y = 2")
        let accepted = controller.acceptGhostText()
        #expect(accepted == "let y = 2")
        #expect(controller.ghostText == nil)
        #expect(updates.contains("let "))
        #expect(updates.contains("let y = 2"))
    }

    @Test func editCancelsStreamAndClearsGhost() async throws {
        let controller = makeController(.stream(["a", "b", "c", "d"], delayMilliseconds: 80))
        controller.requestManually { [request = request()] in request }
        try await Task.sleep(for: .milliseconds(120))

        // A user edit arrives mid-stream.
        controller.noteEdit(isEligible: { false }, context: { nil })
        #expect(controller.ghostText == nil)
        try await Task.sleep(for: .milliseconds(250))
        #expect(controller.ghostText == nil)
    }

    @Test func failureSurfacesNonmodallyAndClearsGhost() async throws {
        let controller = makeController(.fail(.httpError(status: 500, message: "boom")))
        AICompletionStatus.shared.lastError = nil
        controller.requestManually { [request = request()] in request }
        try await Task.sleep(for: .milliseconds(200))

        #expect(controller.ghostText == nil)
        #expect(AICompletionStatus.shared.lastError?.contains("boom") == true)
        AICompletionStatus.shared.lastError = nil
    }

    @Test func dismissDropsGhostWithoutInserting() async throws {
        let controller = makeController(.stream(["suggestion"], delayMilliseconds: 5))
        controller.requestManually { [request = request()] in request }
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.ghostText == "suggestion")

        controller.dismissGhostText()
        #expect(controller.ghostText == nil)
        #expect(controller.acceptGhostText() == nil)
    }
}

@Suite("Credential store")
struct CredentialStoreTests {
    @Test func setGetRemoveRoundTrip() throws {
        defer { try? CredentialStore.setSecret(nil, for: .openAI) }

        try CredentialStore.setSecret("sk-test-123", for: .openAI)
        #expect(try CredentialStore.secret(for: .openAI) == "sk-test-123")
        #expect(CredentialStore.hasSecret(for: .openAI))

        try CredentialStore.setSecret("sk-updated", for: .openAI)
        #expect(try CredentialStore.secret(for: .openAI) == "sk-updated")

        try CredentialStore.setSecret(nil, for: .openAI)
        #expect(try CredentialStore.secret(for: .openAI) == nil)
        #expect(!CredentialStore.hasSecret(for: .openAI))
    }

    @Test @MainActor func serializedSettingsNeverContainSecrets() throws {
        defer { try? CredentialStore.setSecret(nil, for: .anthropic) }
        try CredentialStore.setSecret("sk-ant-super-secret", for: .anthropic)

        let suiteName = "ai-settings-leak-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AISettings(defaults: defaults)
        settings.grantConsent(for: .anthropic)
        settings.selectedProvider = .anthropic
        settings.setModel("claude-sonnet-5", for: .anthropic)
        settings.automaticCompletionEnabled = true

        let data = defaults.data(forKey: "aiSettings.v1")
        #expect(data != nil)
        let json = String(data: data ?? Data(), encoding: .utf8) ?? ""
        #expect(!json.contains("sk-ant-super-secret"))
        #expect(!json.lowercased().contains("secret"))
        #expect(json.contains("anthropic"))
    }
}
