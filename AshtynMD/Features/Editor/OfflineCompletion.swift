import Foundation

/// Local, network-free completion: language keywords plus identifiers and
/// words already present in the document. Shown in the native completion popup.
enum OfflineCompletion {
    static let keywords: [LanguageID: [String]] = [
        .swift: [
            "actor", "as", "associatedtype", "async", "await", "break", "case", "catch",
            "class", "continue", "default", "defer", "deinit", "do", "else", "enum",
            "extension", "fallthrough", "false", "fileprivate", "final", "for", "func",
            "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is",
            "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator",
            "override", "private", "protocol", "public", "repeat", "required", "rethrows",
            "return", "self", "some", "static", "struct", "subscript", "super", "switch",
            "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while",
        ],
        .python: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break",
            "class", "continue", "def", "del", "elif", "else", "except", "finally", "for",
            "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
            "or", "pass", "raise", "return", "try", "while", "with", "yield",
        ],
        .javascript: [
            "async", "await", "break", "case", "catch", "class", "const", "continue",
            "debugger", "default", "delete", "do", "else", "export", "extends", "false",
            "finally", "for", "function", "if", "import", "in", "instanceof", "let",
            "new", "null", "of", "return", "static", "super", "switch", "this", "throw",
            "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
        ],
        .typescript: [
            "abstract", "any", "as", "async", "await", "boolean", "break", "case",
            "catch", "class", "const", "continue", "declare", "default", "delete", "do",
            "else", "enum", "export", "extends", "false", "finally", "for", "function",
            "if", "implements", "import", "in", "infer", "instanceof", "interface",
            "keyof", "let", "namespace", "never", "new", "null", "number", "of",
            "readonly", "return", "satisfies", "static", "string", "super", "switch",
            "this", "throw", "true", "try", "type", "typeof", "undefined", "unknown",
            "var", "void", "while", "yield",
        ],
        .json: ["true", "false", "null"],
        .yaml: ["true", "false", "null", "yes", "no"],
        .html: [
            "a", "article", "aside", "body", "button", "div", "footer", "form", "h1",
            "h2", "h3", "head", "header", "html", "img", "input", "label", "li", "link",
            "main", "meta", "nav", "ol", "p", "script", "section", "select", "span",
            "style", "table", "td", "textarea", "th", "title", "tr", "ul",
        ],
        .css: [
            "align-items", "background", "background-color", "border", "border-radius",
            "bottom", "color", "display", "flex", "flex-direction", "font-family",
            "font-size", "font-weight", "gap", "grid", "height", "justify-content",
            "left", "line-height", "margin", "max-width", "min-height", "opacity",
            "overflow", "padding", "position", "right", "text-align", "top", "transform",
            "transition", "width", "z-index",
        ],
        .shell: [
            "case", "do", "done", "elif", "else", "esac", "exit", "export", "fi", "for",
            "function", "if", "in", "local", "read", "return", "then", "until", "while",
            "echo", "printf", "source", "set", "unset", "shift", "trap",
        ],
        .markdown: [],
        .plainText: [],
    ]

    private static let wordRegex = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]{2,}")
    private static let scanLimit = 200_000

    /// Completions for `prefix`, keywords first, then document words.
    static func completions(
        forPrefix prefix: String,
        language: LanguageID,
        documentText: String
    ) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let lowered = prefix.lowercased()

        let keywordMatches = (keywords[language] ?? [])
            .filter { $0.lowercased().hasPrefix(lowered) && $0 != prefix }

        let sample = String(documentText.prefix(scanLimit)) as NSString
        var seen = Set(keywordMatches)
        seen.insert(prefix)
        var wordMatches: [String] = []
        wordRegex.enumerateMatches(
            in: sample as String, range: NSRange(location: 0, length: sample.length)
        ) { match, _, _ in
            guard let match else { return }
            let word = sample.substring(with: match.range)
            guard word.lowercased().hasPrefix(lowered), !seen.contains(word) else { return }
            seen.insert(word)
            wordMatches.append(word)
        }
        wordMatches.sort()
        return keywordMatches + wordMatches
    }
}
