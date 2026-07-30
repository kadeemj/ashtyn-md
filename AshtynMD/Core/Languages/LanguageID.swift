import Foundation

/// Stable identifier for every language Ashtyn MD understands.
enum LanguageID: String, Codable, Sendable, CaseIterable, Identifiable {
    case markdown
    case plainText
    case swift
    case python
    case javascript
    case typescript
    case json
    case yaml
    case html
    case css
    case shell

    var id: String { rawValue }
}

/// Static description of a supported language: how it is named, detected,
/// and commented. Appearance lives in `EditorProfile`, not here.
struct LanguageDefinition: Sendable {
    let id: LanguageID
    let displayName: String
    /// Lowercased file extensions, without the leading dot.
    let extensions: [String]
    /// Interpreter names matched against a `#!` line (e.g. "python3").
    let shebangInterpreters: [String]
    /// Identifiers and aliases used in Markdown fenced-code blocks.
    let fenceAliases: [String]
    let lineCommentPrefix: String?
    let blockComment: (start: String, end: String)?
    /// Extension used when creating a new file of this language.
    let preferredExtension: String

    static let all: [LanguageDefinition] = [
        LanguageDefinition(
            id: .markdown, displayName: "Markdown",
            extensions: ["md", "markdown"],
            shebangInterpreters: [],
            fenceAliases: ["markdown", "md"],
            lineCommentPrefix: nil, blockComment: ("<!--", "-->"),
            preferredExtension: "md"
        ),
        LanguageDefinition(
            id: .plainText, displayName: "Plain Text",
            extensions: ["txt", "text"],
            shebangInterpreters: [],
            fenceAliases: ["text", "txt", "plaintext"],
            lineCommentPrefix: nil, blockComment: nil,
            preferredExtension: "txt"
        ),
        LanguageDefinition(
            id: .swift, displayName: "Swift",
            extensions: ["swift"],
            shebangInterpreters: ["swift"],
            fenceAliases: ["swift"],
            lineCommentPrefix: "//", blockComment: ("/*", "*/"),
            preferredExtension: "swift"
        ),
        LanguageDefinition(
            id: .python, displayName: "Python",
            extensions: ["py"],
            shebangInterpreters: ["python", "python2", "python3"],
            fenceAliases: ["python", "py", "python3"],
            lineCommentPrefix: "#", blockComment: nil,
            preferredExtension: "py"
        ),
        LanguageDefinition(
            id: .javascript, displayName: "JavaScript",
            extensions: ["js", "jsx", "mjs", "cjs"],
            shebangInterpreters: ["node", "nodejs"],
            fenceAliases: ["javascript", "js", "jsx", "node"],
            lineCommentPrefix: "//", blockComment: ("/*", "*/"),
            preferredExtension: "js"
        ),
        LanguageDefinition(
            id: .typescript, displayName: "TypeScript",
            extensions: ["ts", "tsx"],
            shebangInterpreters: ["ts-node", "deno", "bun"],
            fenceAliases: ["typescript", "ts", "tsx"],
            lineCommentPrefix: "//", blockComment: ("/*", "*/"),
            preferredExtension: "ts"
        ),
        LanguageDefinition(
            id: .json, displayName: "JSON",
            extensions: ["json"],
            shebangInterpreters: [],
            fenceAliases: ["json", "jsonc"],
            lineCommentPrefix: nil, blockComment: nil,
            preferredExtension: "json"
        ),
        LanguageDefinition(
            id: .yaml, displayName: "YAML",
            extensions: ["yaml", "yml"],
            shebangInterpreters: [],
            fenceAliases: ["yaml", "yml"],
            lineCommentPrefix: "#", blockComment: nil,
            preferredExtension: "yaml"
        ),
        LanguageDefinition(
            id: .html, displayName: "HTML",
            extensions: ["html", "htm"],
            shebangInterpreters: [],
            fenceAliases: ["html", "htm", "xhtml"],
            lineCommentPrefix: nil, blockComment: ("<!--", "-->"),
            preferredExtension: "html"
        ),
        LanguageDefinition(
            id: .css, displayName: "CSS",
            extensions: ["css"],
            shebangInterpreters: [],
            fenceAliases: ["css"],
            lineCommentPrefix: nil, blockComment: ("/*", "*/"),
            preferredExtension: "css"
        ),
        LanguageDefinition(
            id: .shell, displayName: "Shell",
            extensions: ["sh", "bash", "zsh"],
            shebangInterpreters: ["sh", "bash", "zsh", "dash", "ksh"],
            fenceAliases: ["shell", "sh", "bash", "zsh", "shellscript", "console"],
            lineCommentPrefix: "#", blockComment: nil,
            preferredExtension: "sh"
        ),
    ]

    static func definition(for id: LanguageID) -> LanguageDefinition {
        // `all` covers every case; force-unwrap would hide a future gap, so fall
        // back to plain text if a case is ever added without a definition.
        all.first { $0.id == id } ?? all.first { $0.id == .plainText }!
    }
}
