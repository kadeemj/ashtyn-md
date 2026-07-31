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
    /// Base font. Proportional for Markdown, monospace for code.
    var fontFamily: String
    var fontSize: Double
    var lineHeightMultiple: Double
    var tabWidth: Int
    var usesTabs: Bool
    var wrapsLines: Bool
    var tokenColors: [SyntaxToken: CodableColor]

    // MARK: Markdown presentation

    /// Font for code spans and fenced blocks inside a Markdown document.
    var monospaceFontFamily: String = "SF Mono"
    /// Multipliers on `fontSize` for heading levels 1 through 6.
    var headingScales: [Double] = [1.80, 1.50, 1.30, 1.15, 1.05, 1.00]
    /// Overrides on top of `MarkdownRoleStyle.standard(for:)`.
    var roleStyles: [MarkdownStyleRole: MarkdownRoleStyle] = [:]
    var markerVisibility: MarkerVisibility = .caretLine
    var rendersTagPills: Bool = true
    var focusModeEnabled: Bool = false
    var typewriterModeEnabled: Bool = false
    var paragraphSpacing: Double = 8
    /// Caps the text column width in points; nil fills the view.
    var contentWidthLimit: Double?

    /// The resolved style for a role, overrides applied.
    func roleStyle(for role: MarkdownStyleRole) -> MarkdownRoleStyle {
        roleStyles[role] ?? .standard(for: role)
    }

    /// Point size for a heading level, clamped to the table.
    func headingSize(level: Int) -> Double {
        guard !headingScales.isEmpty else { return fontSize }
        let index = min(max(level - 1, 0), headingScales.count - 1)
        return fontSize * headingScales[index]
    }

    static func defaultProfile(for language: LanguageID) -> EditorProfile {
        switch language {
        case .markdown:
            // Prose, so a proportional face. Code inside the note still uses
            // monospaceFontFamily.
            return EditorProfile(
                fontFamily: "SF Pro Text", fontSize: 16, lineHeightMultiple: 1.45,
                tabWidth: 4, usesTabs: false, wrapsLines: true, tokenColors: [:]
            )
        case .plainText:
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

    init(
        fontFamily: String,
        fontSize: Double,
        lineHeightMultiple: Double,
        tabWidth: Int,
        usesTabs: Bool,
        wrapsLines: Bool,
        tokenColors: [SyntaxToken: CodableColor]
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeightMultiple = lineHeightMultiple
        self.tabWidth = tabWidth
        self.usesTabs = usesTabs
        self.wrapsLines = wrapsLines
        self.tokenColors = tokenColors
    }

    /// Hand-written because Swift's synthesized `init(from:)` throws
    /// `keyNotFound` for an absent key rather than applying the property's
    /// default value — so every profile written by a previous version would
    /// fail to decode the moment a field is added. Every key is optional and
    /// falls back, including the original ones, so this never has to be
    /// revisited when the shape changes again.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = EditorProfile(
            fontFamily: "SF Mono", fontSize: 13, lineHeightMultiple: 1.3,
            tabWidth: 4, usesTabs: false, wrapsLines: false, tokenColors: [:]
        )

        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
            ?? fallback.fontFamily
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
            ?? fallback.fontSize
        lineHeightMultiple = try container.decodeIfPresent(Double.self, forKey: .lineHeightMultiple)
            ?? fallback.lineHeightMultiple
        tabWidth = try container.decodeIfPresent(Int.self, forKey: .tabWidth) ?? fallback.tabWidth
        usesTabs = try container.decodeIfPresent(Bool.self, forKey: .usesTabs) ?? fallback.usesTabs
        wrapsLines = try container.decodeIfPresent(Bool.self, forKey: .wrapsLines)
            ?? fallback.wrapsLines
        tokenColors = try container.decodeIfPresent(
            [SyntaxToken: CodableColor].self, forKey: .tokenColors
        ) ?? [:]

        monospaceFontFamily = try container.decodeIfPresent(
            String.self, forKey: .monospaceFontFamily
        ) ?? "SF Mono"
        headingScales = try container.decodeIfPresent([Double].self, forKey: .headingScales)
            ?? [1.80, 1.50, 1.30, 1.15, 1.05, 1.00]
        roleStyles = try container.decodeIfPresent(
            [MarkdownStyleRole: MarkdownRoleStyle].self, forKey: .roleStyles
        ) ?? [:]
        markerVisibility = try container.decodeIfPresent(
            MarkerVisibility.self, forKey: .markerVisibility
        ) ?? .caretLine
        rendersTagPills = try container.decodeIfPresent(Bool.self, forKey: .rendersTagPills) ?? true
        focusModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .focusModeEnabled)
            ?? false
        typewriterModeEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .typewriterModeEnabled
        ) ?? false
        paragraphSpacing = try container.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 8
        contentWidthLimit = try container.decodeIfPresent(Double.self, forKey: .contentWidthLimit)
    }
}
