import Foundation

/// Semantic token classes produced by syntax highlighting (Phase 3) and
/// colored per profile. Stable serialization keys — do not rename cases.
enum SyntaxToken: String, Codable, Sendable, CaseIterable {
    case keyword
    case string
    case number
    case comment
    case type
    case function
    case variable
    case property
    case `operator`
    case punctuation
    case markupHeading
    case markupEmphasis
    case markupLink
    case markupCode
}

/// sRGB color that survives Codable round-trips without AppKit.
struct CodableColor: Codable, Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
}

/// Editable appearance and behavior for one language. Appearance never
/// changes file contents.
struct EditorProfile: Codable, Sendable, Equatable {
    var fontFamily: String
    var fontSize: Double
    var lineHeightMultiple: Double
    var tabWidth: Int
    var usesTabs: Bool
    var wrapsLines: Bool
    var tokenColors: [SyntaxToken: CodableColor]

    static func defaultProfile(for language: LanguageID) -> EditorProfile {
        switch language {
        case .markdown, .plainText:
            return EditorProfile(
                fontFamily: "SF Mono", fontSize: 15, lineHeightMultiple: 1.45,
                tabWidth: 4, usesTabs: false, wrapsLines: true, tokenColors: [:]
            )
        case .swift, .python:
            return EditorProfile(
                fontFamily: "SF Mono", fontSize: 13, lineHeightMultiple: 1.30,
                tabWidth: 4, usesTabs: false, wrapsLines: false, tokenColors: [:]
            )
        case .javascript, .typescript, .json, .yaml, .html, .css, .shell:
            return EditorProfile(
                fontFamily: "SF Mono", fontSize: 13, lineHeightMultiple: 1.30,
                tabWidth: 2, usesTabs: false, wrapsLines: false, tokenColors: [:]
            )
        }
    }
}
