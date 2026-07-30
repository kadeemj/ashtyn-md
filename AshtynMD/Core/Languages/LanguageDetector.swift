import Foundation

/// Detects the language of a file. Order is fixed by the product spec:
/// explicit user override → extension → shebang → lightweight content
/// detection → plain text.
enum LanguageDetector {
    static func detect(
        fileName: String,
        contents: String?,
        override: LanguageID? = nil
    ) -> LanguageID {
        if let override { return override }
        if let byExtension = detectByExtension(fileName: fileName) { return byExtension }
        if let contents {
            if let byShebang = detectByShebang(contents: contents) { return byShebang }
            if let byContent = detectByContent(contents: contents) { return byContent }
        }
        return .plainText
    }

    static func detectByExtension(fileName: String) -> LanguageID? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return LanguageDefinition.all.first { $0.extensions.contains(ext) }?.id
    }

    static func detectByShebang(contents: String) -> LanguageID? {
        guard contents.hasPrefix("#!") else { return nil }
        let firstLine = contents.prefix(while: { $0 != "\n" && $0 != "\r" })
        let line = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        var parts = line.split(separator: " ").map(String.init)
        guard let interpreterPath = parts.first else { return nil }
        var interpreter = (interpreterPath as NSString).lastPathComponent
        // `#!/usr/bin/env python3` names the real interpreter second.
        if interpreter == "env", parts.count > 1 {
            parts.removeFirst()
            interpreter = parts.first.map { ($0 as NSString).lastPathComponent } ?? ""
        }
        // Strip trailing version digits and dots: python3.12 → python3 → python.
        let base = interpreter.lowercased()
        for definition in LanguageDefinition.all {
            for candidate in definition.shebangInterpreters {
                if base == candidate || base.hasPrefix(candidate) &&
                    base.dropFirst(candidate.count).allSatisfy({ $0.isNumber || $0 == "." }) {
                    return definition.id
                }
            }
        }
        return nil
    }

    /// Cheap structural checks only — no full parsing of large documents.
    static func detectByContent(contents: String) -> LanguageID? {
        let sample = String(contents.prefix(4096))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("<!doctype html") || lowered.hasPrefix("<html") {
            return .html
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            // Only claim JSON when the (small) document actually parses.
            if contents.utf8.count <= 256 * 1024,
               let data = contents.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                return .json
            }
        }
        return nil
    }

    /// Resolves a Markdown fence identifier such as ```swift or ```py.
    static func language(forFenceIdentifier identifier: String) -> LanguageID? {
        let normalized = identifier.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return nil }
        return LanguageDefinition.all.first { $0.fenceAliases.contains(normalized) }?.id
    }
}
