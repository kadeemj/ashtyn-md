import Foundation
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterPython
import TreeSitterJavaScript
import TreeSitterTypeScript
import TreeSitterJSON
import TreeSitterYAML
import TreeSitterHTML
import TreeSitterCSS
import TreeSitterBash
import TreeSitterMarkdown

/// Loads and caches Tree-sitter language configurations (grammar plus its
/// bundled highlight queries). A missing or broken grammar simply yields nil:
/// the editor falls back to plain text.
enum GrammarRegistry {
    /// Anchor for locating the app bundle even inside a hosted test runner,
    /// where SwiftTreeSitter's own bundle heuristics look in the wrong place.
    private final class BundleAnchor {}

    private static func queriesURL(forBundleNamed bundleName: String) -> URL? {
        let candidates = [
            Bundle(for: BundleAnchor.self).resourceURL,
            Bundle.main.resourceURL,
        ]
        for base in candidates.compactMap({ $0 }) {
            let url = base
                .appendingPathComponent("\(bundleName).bundle", isDirectory: true)
                .appendingPathComponent("Contents/Resources/queries", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Built once; LanguageConfiguration is Sendable.
    private static let configurations: [LanguageID: LanguageConfiguration] = {
        var result: [LanguageID: LanguageConfiguration] = [:]
        // Query loading reads highlights.scm from each grammar's SPM bundle.
        func load(_ id: LanguageID, _ tsLanguage: OpaquePointer, _ name: String) {
            let bundleName = "TreeSitter\(name)_TreeSitter\(name)"
            guard let queriesURL = queriesURL(forBundleNamed: bundleName) else { return }
            result[id] = try? LanguageConfiguration(
                tsLanguage, name: name, queriesURL: queriesURL
            )
        }
        load(.swift, tree_sitter_swift(), "Swift")
        load(.python, tree_sitter_python(), "Python")
        load(.javascript, tree_sitter_javascript(), "JavaScript")
        load(.typescript, tree_sitter_typescript(), "TypeScript")
        load(.json, tree_sitter_json(), "JSON")
        load(.yaml, tree_sitter_yaml(), "YAML")
        load(.html, tree_sitter_html(), "HTML")
        load(.css, tree_sitter_css(), "CSS")
        load(.shell, tree_sitter_bash(), "Bash")
        load(.markdown, tree_sitter_markdown(), "Markdown")
        return result
    }()

    static func configuration(for id: LanguageID) -> LanguageConfiguration? {
        configurations[id]
    }
}

/// Maps Tree-sitter highlight capture names (e.g. "keyword", "string.special",
/// "punctuation.bracket") onto Ashtyn MD's fixed token set.
enum CaptureNameMapper {
    static func token(forCaptureComponents components: [String]) -> SyntaxToken? {
        guard let first = components.first else { return nil }
        switch first {
        case "keyword", "conditional", "repeat", "include", "exception", "label",
             "storageclass", "boolean":
            return .keyword
        case "string", "character", "text.literal":
            return .string
        case "number", "float", "constant":
            return .number
        case "comment":
            return .comment
        case "type", "tag", "namespace", "structure":
            return .type
        case "function", "method", "constructor":
            return .function
        case "variable", "parameter":
            return .variable
        case "property", "attribute", "field":
            return .property
        case "operator":
            return .operator
        case "punctuation", "delimiter", "bracket":
            return .punctuation
        case "markup":
            switch components.dropFirst().first {
            case "heading": return .markupHeading
            case "bold", "italic", "strong", "emphasis", "strikethrough": return .markupEmphasis
            case "link", "url", "reference": return .markupLink
            case "raw", "code": return .markupCode
            case "list": return .punctuation
            default: return nil
            }
        case "text":
            switch components.dropFirst().first {
            case "title": return .markupHeading
            case "emphasis", "strong": return .markupEmphasis
            case "uri", "reference": return .markupLink
            default: return nil
            }
        default:
            return nil
        }
    }
}
