import Foundation
import Observation

/// Persisted per-language editor profiles and the selected theme, stored as
/// versioned JSON at ~/Library/Application Support/Ashtyn MD/editor-profiles-v1.json.
@MainActor
@Observable
final class EditorProfilesStore {
    static let shared = EditorProfilesStore()

    private struct Payload: Codable {
        var version: Int = 1
        var themeID: String = EditorTheme.system.id
        var profiles: [String: EditorProfile] = [:]
    }

    private(set) var profiles: [LanguageID: EditorProfile] = [:]
    var themeID: String = EditorTheme.system.id {
        didSet { save() }
    }

    var theme: EditorTheme {
        EditorTheme.theme(withID: themeID)
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppSupportPaths.editorProfilesFile
        load()
    }

    private let fileURL: URL

    /// The effective profile: stored override or the built-in default.
    func profile(for language: LanguageID) -> EditorProfile {
        profiles[language] ?? .defaultProfile(for: language)
    }

    func update(_ profile: EditorProfile, for language: LanguageID) {
        if profile == .defaultProfile(for: language) {
            profiles.removeValue(forKey: language)
        } else {
            profiles[language] = profile
        }
        save()
    }

    func reset(_ language: LanguageID) {
        profiles.removeValue(forKey: language)
        save()
    }

    func resetAll() {
        profiles = [:]
        themeID = EditorTheme.system.id
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        themeID = payload.themeID
        profiles = payload.profiles.reduce(into: [:]) { result, entry in
            guard let id = LanguageID(rawValue: entry.key) else { return }
            result[id] = entry.value
        }
    }

    private func save() {
        var payload = Payload()
        payload.themeID = themeID
        payload.profiles = profiles.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? AppSupportPaths.ensureExists(fileURL.deletingLastPathComponent())
        try? SaveCoordinator.writeAtomically(data, to: fileURL)
    }
}
