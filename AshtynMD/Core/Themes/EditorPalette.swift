import AppKit

/// Every color one appearance of a theme needs.
///
/// Phase 7 promoted this from a bare `[SyntaxToken: CodableColor]` because a
/// Bear-like editor themes its own chrome — background, caret, selection,
/// current line — rather than inheriting AppKit's semantic colors.
struct EditorPalette: Codable, Sendable, Equatable {
    var background: CodableColor
    var foreground: CodableColor
    var caret: CodableColor
    var selection: CodableColor
    var currentLine: CodableColor
    /// Links and tags.
    var accent: CodableColor
    var tagPillBackground: CodableColor
    /// Markdown markers when they are not on the caret line.
    var markerDim: CodableColor
    /// Paragraphs outside the focused one.
    var focusDim: CodableColor
    /// Thematic breaks and the blockquote bar.
    var rule: CodableColor
    var codeBackground: CodableColor
    var tokens: [SyntaxToken: CodableColor]
    /// Per-role overrides; roles without one fall back to `token(for:)`.
    var roles: [MarkdownStyleRole: CodableColor] = [:]

    /// Resolves a Markdown role to a color, falling back through the syntax
    /// token palette so a theme only has to specify what it wants to change.
    func color(for role: MarkdownStyleRole) -> CodableColor {
        if let override = roles[role] { return override }
        switch role {
        case .heading, .headingMarker:
            return tokens[.markupHeading] ?? foreground
        case .bold, .italic, .boldItalic, .strikethrough:
            return tokens[.markupEmphasis] ?? foreground
        case .inlineCode, .codeBlock, .codeFence, .codeInfoString, .inlineCodeMarker:
            return tokens[.markupCode] ?? foreground
        case .linkText, .linkURL, .autolink, .wikiLink:
            return accent
        case .tag:
            return accent
        case .blockQuote:
            return foreground
        case .blockQuoteMarker, .thematicBreak:
            return rule
        case .listMarker, .taskMarkerUnchecked:
            return tokens[.punctuation] ?? markerDim
        case .taskMarkerChecked:
            return accent
        case .emphasisMarker, .linkMarker, .imageMarker, .wikiLinkMarker, .escape:
            return markerDim
        case .frontMatter:
            return tokens[.comment] ?? markerDim
        }
    }
}

/// A named pair of palettes. "System" follows the window appearance; the
/// others force one regardless.
struct EditorTheme: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var light: EditorPalette
    var dark: EditorPalette
    /// nil follows the system appearance.
    var forcedAppearance: ForcedAppearance?

    enum ForcedAppearance: String, Codable, Sendable {
        case light
        case dark
    }

    func palette(forDarkAppearance isDark: Bool) -> EditorPalette {
        switch forcedAppearance {
        case .light: return light
        case .dark: return dark
        case nil: return isDark ? dark : light
        }
    }

    // MARK: - Built-in themes

    private static func rgb(_ hex: UInt32, alpha: Double = 1) -> CodableColor {
        CodableColor(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static let lightTokens: [SyntaxToken: CodableColor] = [
        .keyword: rgb(0x9C1E93), .string: rgb(0xC41A17), .number: rgb(0x1C00CF),
        .comment: rgb(0x007400), .type: rgb(0x3900A0), .function: rgb(0x326D74),
        .variable: rgb(0x0D0D0D), .property: rgb(0x326D74), .operator: rgb(0x333333),
        .punctuation: rgb(0x8A8A8A), .markupHeading: rgb(0x0A4F78),
        .markupEmphasis: rgb(0x1D1D1F), .markupLink: rgb(0x0A66C2),
        .markupCode: rgb(0xC41A17),
    ]

    private static let darkTokens: [SyntaxToken: CodableColor] = [
        .keyword: rgb(0xFC5FA3), .string: rgb(0xFC6A5D), .number: rgb(0xD0BF69),
        .comment: rgb(0x6C7986), .type: rgb(0x5DD8FF), .function: rgb(0x67B7A4),
        .variable: rgb(0xE6E6E6), .property: rgb(0x67B7A4), .operator: rgb(0xCCCCCC),
        .punctuation: rgb(0x8A8A8A), .markupHeading: rgb(0x5DD8FF),
        .markupEmphasis: rgb(0xE8E8E8), .markupLink: rgb(0x7AA2F7),
        .markupCode: rgb(0xFC6A5D),
    ]

    private static let systemLight = EditorPalette(
        background: rgb(0xFFFFFF), foreground: rgb(0x1D1D1F), caret: rgb(0x0A66C2),
        selection: rgb(0xB4D8FE), currentLine: rgb(0xF2F5F9), accent: rgb(0x0A66C2),
        tagPillBackground: rgb(0xE4EEF9), markerDim: rgb(0xB8BCC2),
        focusDim: rgb(0xB0B4BA), rule: rgb(0xD6D9DE), codeBackground: rgb(0xF4F4F6),
        tokens: lightTokens
    )

    private static let systemDark = EditorPalette(
        background: rgb(0x1E1E1E), foreground: rgb(0xE8E8E8), caret: rgb(0x7AA2F7),
        selection: rgb(0x2F4A73), currentLine: rgb(0x272727), accent: rgb(0x7AA2F7),
        tagPillBackground: rgb(0x2A3550), markerDim: rgb(0x5A5F66),
        focusDim: rgb(0x62676E), rule: rgb(0x3A3A3A), codeBackground: rgb(0x262626),
        tokens: darkTokens
    )

    /// Warm paper, for long-form writing.
    private static let paper = EditorPalette(
        background: rgb(0xFBF7EF), foreground: rgb(0x33302B), caret: rgb(0xA6551B),
        selection: rgb(0xEADCC4), currentLine: rgb(0xF4EEE1), accent: rgb(0xA6551B),
        tagPillBackground: rgb(0xEFE3CE), markerDim: rgb(0xC0B49C),
        focusDim: rgb(0xB3A891), rule: rgb(0xDDD2BC), codeBackground: rgb(0xF1EADB),
        tokens: lightTokens.merging([
            .markupHeading: rgb(0x7A3E12),
            .markupEmphasis: rgb(0x33302B),
            .markupLink: rgb(0xA6551B),
            .markupCode: rgb(0x8A5A2B),
        ]) { _, new in new }
    )

    /// Cool and high-contrast.
    private static let midnight = EditorPalette(
        background: rgb(0x14161F), foreground: rgb(0xD8DEE9), caret: rgb(0x88C0D0),
        selection: rgb(0x2B3A55), currentLine: rgb(0x1B1E29), accent: rgb(0x88C0D0),
        tagPillBackground: rgb(0x223143), markerDim: rgb(0x4C566A),
        focusDim: rgb(0x555F70), rule: rgb(0x2E3440), codeBackground: rgb(0x1A1D27),
        tokens: darkTokens.merging([
            .markupHeading: rgb(0x8FBCBB),
            .markupEmphasis: rgb(0xD8DEE9),
            .markupLink: rgb(0x88C0D0),
            .markupCode: rgb(0xEBCB8B),
        ]) { _, new in new }
    )

    /// Muted grey-blue, closer to GitHub's dark dimmed.
    private static let slate = EditorPalette(
        background: rgb(0x22272E), foreground: rgb(0xADBAC7), caret: rgb(0x6CB6FF),
        selection: rgb(0x2D4A68), currentLine: rgb(0x2A2F37), accent: rgb(0x6CB6FF),
        tagPillBackground: rgb(0x253242), markerDim: rgb(0x545D68),
        focusDim: rgb(0x5C6672), rule: rgb(0x373E47), codeBackground: rgb(0x2A2F37),
        tokens: darkTokens.merging([
            .markupHeading: rgb(0x6CB6FF),
            .markupEmphasis: rgb(0xADBAC7),
            .markupLink: rgb(0x6CB6FF),
            .markupCode: rgb(0xF69D50),
        ]) { _, new in new }
    )

    static let system = EditorTheme(
        id: "system", name: "System", light: systemLight, dark: systemDark,
        forcedAppearance: nil
    )
    /// Keeps the legacy "light" id so an existing stored preference still
    /// resolves to a forced-light theme.
    static let paperTheme = EditorTheme(
        id: "light", name: "Paper", light: paper, dark: paper,
        forcedAppearance: .light
    )
    static let midnightTheme = EditorTheme(
        id: "dark", name: "Midnight", light: midnight, dark: midnight,
        forcedAppearance: .dark
    )
    static let slateTheme = EditorTheme(
        id: "slate", name: "Slate", light: slate, dark: slate,
        forcedAppearance: .dark
    )

    static let builtIn: [EditorTheme] = [.system, .paperTheme, .midnightTheme, .slateTheme]

    static func theme(withID id: String) -> EditorTheme {
        builtIn.first { $0.id == id } ?? .system
    }
}

extension CodableColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    init(nsColor: NSColor) {
        let converted = nsColor.usingColorSpace(.sRGB) ?? .black
        self.init(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }

    /// Blends toward `other`, used for role opacity and marker dimming.
    func blended(toward other: CodableColor, amount: Double) -> CodableColor {
        let clamped = min(max(amount, 0), 1)
        return CodableColor(
            red: red + (other.red - red) * clamped,
            green: green + (other.green - green) * clamped,
            blue: blue + (other.blue - blue) * clamped,
            alpha: alpha
        )
    }
}
