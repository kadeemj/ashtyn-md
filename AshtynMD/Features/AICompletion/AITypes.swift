import Foundation

enum AIProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama"
        }
    }

    /// Cloud providers require the one-time context-transmission disclosure.
    var isCloud: Bool {
        self != .ollama
    }
}

struct AIModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
}

struct AICompletionRequest: Sendable {
    enum Trigger: Sendable {
        case manual
        case automatic
    }

    let language: LanguageID
    let fileName: String
    let prefix: String
    let suffix: String
    /// Leading file characters when the prefix window doesn't reach the top.
    let documentHead: String?
    let trigger: Trigger
    let maximumOutputCharacters: Int
}

struct AIUsage: Sendable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
}

enum AICompletionEvent: Sendable {
    case textDelta(String)
    case completed(AIUsage?)
}

enum AIProviderError: Error, LocalizedError, Equatable {
    case notConfigured(String)
    case httpError(status: Int, message: String)
    case rateLimited(retryAfterSeconds: Double?)
    case invalidResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what):
            return what
        case .httpError(let status, let message):
            return "Provider error (\(status)): \(message)"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited — retry in \(Int(retryAfter.rounded()))s"
            }
            return "Rate limited by the provider"
        case .invalidResponse(let detail):
            return "Unexpected provider response: \(detail)"
        case .network(let detail):
            return "Network error: \(detail)"
        }
    }
}

protocol AICompletionProvider: Sendable {
    var id: AIProviderID { get }
    func availableModels() async throws -> [AIModel]
    func validateConfiguration() async throws
    func complete(
        _ request: AICompletionRequest
    ) -> AsyncThrowingStream<AICompletionEvent, Error>
}

/// Builds the system instruction and per-request user content shared by all
/// providers. Only current-file context is ever included.
enum AIPrompt {
    static let systemInstruction = """
    You are an inline completion engine inside a text editor. The user content \
    contains the text before the cursor (prefix) and after the cursor (suffix). \
    Reply with ONLY the exact characters to insert at the cursor position. \
    Do not repeat the prefix or suffix. Do not wrap the reply in Markdown code \
    fences. Do not add any explanation or commentary. If nothing useful can be \
    inserted, reply with an empty string.
    """

    static func userContent(for request: AICompletionRequest) -> String {
        var parts: [String] = []
        parts.append("File: \(request.fileName)")
        parts.append("Language: \(LanguageDefinition.definition(for: request.language).displayName)")
        if let head = request.documentHead, !head.isEmpty {
            parts.append("Document start:\n\(head)")
        }
        parts.append("Text before cursor:\n\(request.prefix)")
        parts.append("Text after cursor:\n\(request.suffix)")
        parts.append("Insert at cursor:")
        return parts.joined(separator: "\n\n")
    }
}
