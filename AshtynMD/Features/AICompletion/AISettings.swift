import Foundation
import Observation

/// AI configuration persisted in UserDefaults as versioned JSON. Never holds
/// secrets — keys live exclusively in the Keychain (CredentialStore).
@MainActor
@Observable
final class AISettings {
    static let shared = AISettings()

    private struct Payload: Codable {
        var version = 1
        var selectedProvider: AIProviderID?
        var modelByProvider: [String: String] = [:]
        var customModelByProvider: [String: String] = [:]
        var ollamaBaseURL: String = ""
        var automaticCompletionEnabled = false
        var consentedProviders: [String] = []
    }

    private static let defaultsKey = "aiSettings.v1"

    var selectedProvider: AIProviderID? {
        didSet { save() }
    }
    private(set) var modelByProvider: [AIProviderID: String] = [:]
    var ollamaBaseURLString: String = "" {
        didSet { save() }
    }
    var automaticCompletionEnabled = false {
        didSet { save() }
    }
    private(set) var consentedProviders: Set<AIProviderID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private let defaults: UserDefaults

    func model(for provider: AIProviderID) -> String {
        modelByProvider[provider] ?? ""
    }

    func setModel(_ model: String, for provider: AIProviderID) {
        modelByProvider[provider] = model
        save()
    }

    func grantConsent(for provider: AIProviderID) {
        consentedProviders.insert(provider)
        save()
    }

    func hasConsent(for provider: AIProviderID) -> Bool {
        !provider.isCloud || consentedProviders.contains(provider)
    }

    var ollamaBaseURL: URL {
        URL(string: ollamaBaseURLString.trimmingCharacters(in: .whitespaces))
            ?? OllamaProvider.defaultBaseURL
    }

    /// Builds the configured provider, reading credentials from the Keychain.
    func makeProvider() -> AICompletionProvider? {
        guard let selectedProvider else { return nil }
        return makeProvider(selectedProvider)
    }

    func makeProvider(_ id: AIProviderID) -> AICompletionProvider? {
        let model = model(for: id)
        switch id {
        case .openAI:
            guard let key = try? CredentialStore.secret(for: .openAI), !key.isEmpty
            else { return nil }
            return OpenAIProvider(apiKey: key, model: model)
        case .anthropic:
            guard let key = try? CredentialStore.secret(for: .anthropic), !key.isEmpty
            else { return nil }
            return AnthropicProvider(apiKey: key, model: model)
        case .ollama:
            return OllamaProvider(model: model, baseURL: ollamaBaseURL)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        selectedProvider = payload.selectedProvider
        modelByProvider = payload.modelByProvider.reduce(into: [:]) { result, entry in
            guard let id = AIProviderID(rawValue: entry.key) else { return }
            result[id] = entry.value
        }
        ollamaBaseURLString = payload.ollamaBaseURL
        automaticCompletionEnabled = payload.automaticCompletionEnabled
        consentedProviders = Set(payload.consentedProviders.compactMap(AIProviderID.init(rawValue:)))
    }

    private func save() {
        var payload = Payload()
        payload.selectedProvider = selectedProvider
        payload.modelByProvider = modelByProvider.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        payload.ollamaBaseURL = ollamaBaseURLString
        payload.automaticCompletionEnabled = automaticCompletionEnabled
        payload.consentedProviders = consentedProviders.map(\.rawValue).sorted()
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Builds current-file-only completion context around the caret, on UTF-16
/// boundaries snapped to composed character sequences.
enum CompletionContext {
    static let maximumPrefix = 16_000
    static let maximumSuffix = 8_000
    static let maximumDocumentHead = 4_000
    static let maximumOutput = 4_000

    static func request(
        text: String,
        caretLocation: Int,
        language: LanguageID,
        fileName: String,
        trigger: AICompletionRequest.Trigger
    ) -> AICompletionRequest {
        let ns = text as NSString
        let caret = min(max(0, caretLocation), ns.length)

        var prefixStart = max(0, caret - maximumPrefix)
        if prefixStart > 0 {
            prefixStart = ns.rangeOfComposedCharacterSequence(at: prefixStart).location
        }
        let prefix = ns.substring(with: NSRange(location: prefixStart, length: caret - prefixStart))

        var suffixEnd = min(ns.length, caret + maximumSuffix)
        if suffixEnd < ns.length && suffixEnd > 0 {
            suffixEnd = ns.rangeOfComposedCharacterSequence(at: suffixEnd - 1).location
                + ns.rangeOfComposedCharacterSequence(at: suffixEnd - 1).length
        }
        let suffix = ns.substring(with: NSRange(location: caret, length: max(0, suffixEnd - caret)))

        // Leading characters for imports/metadata when the prefix window
        // doesn't already start at the top of the file.
        var documentHead: String?
        if prefixStart > 0 {
            var headEnd = min(maximumDocumentHead, prefixStart)
            if headEnd > 0 {
                let sequence = ns.rangeOfComposedCharacterSequence(at: headEnd - 1)
                headEnd = sequence.location + sequence.length
            }
            documentHead = ns.substring(with: NSRange(location: 0, length: min(headEnd, prefixStart)))
        }

        return AICompletionRequest(
            language: language,
            fileName: fileName,
            prefix: prefix,
            suffix: suffix,
            documentHead: documentHead,
            trigger: trigger,
            maximumOutputCharacters: maximumOutput
        )
    }
}
