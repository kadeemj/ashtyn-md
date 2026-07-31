import AppKit

/// Font weight that survives Codable without dragging AppKit into the model.
enum MarkdownFontWeight: String, Codable, Sendable, CaseIterable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

/// How a Markdown role is drawn, relative to the profile's base font.
struct MarkdownRoleStyle: Codable, Sendable, Equatable {
    var sizeMultiple: Double = 1
    var weight: MarkdownFontWeight = .regular
    var isItalic = false
    var isMonospaced = false
    /// Blended toward the background; 1 is fully opaque.
    var opacity: Double = 1

    init(
        sizeMultiple: Double = 1,
        weight: MarkdownFontWeight = .regular,
        isItalic: Bool = false,
        isMonospaced: Bool = false,
        opacity: Double = 1
    ) {
        self.sizeMultiple = sizeMultiple
        self.weight = weight
        self.isItalic = isItalic
        self.isMonospaced = isMonospaced
        self.opacity = opacity
    }

    /// The built-in look. Profiles store only overrides, so this is what a
    /// stock install renders and what the Settings sheet resets to.
    ///
    /// Headings get their size from `EditorProfile.headingScales` instead of
    /// here, because the level is not known from the role alone.
    static func standard(for role: MarkdownStyleRole) -> MarkdownRoleStyle {
        switch role {
        case .heading:
            return MarkdownRoleStyle(weight: .bold)
        case .bold:
            return MarkdownRoleStyle(weight: .bold)
        case .italic:
            return MarkdownRoleStyle(isItalic: true)
        case .boldItalic:
            return MarkdownRoleStyle(weight: .bold, isItalic: true)
        case .tag:
            return MarkdownRoleStyle(weight: .semibold)
        case .inlineCode, .codeBlock, .codeInfoString, .autolink, .linkURL:
            return MarkdownRoleStyle(sizeMultiple: 0.92, isMonospaced: true)
        case .codeFence, .inlineCodeMarker:
            return MarkdownRoleStyle(sizeMultiple: 0.92, isMonospaced: true, opacity: 0.6)
        case .blockQuote:
            return MarkdownRoleStyle(isItalic: true, opacity: 0.85)
        case .linkText, .wikiLink:
            return MarkdownRoleStyle()
        case .strikethrough:
            return MarkdownRoleStyle(opacity: 0.7)
        case .frontMatter:
            return MarkdownRoleStyle(sizeMultiple: 0.9, isMonospaced: true, opacity: 0.7)
        case .thematicBreak:
            // The rule color is already muted; dimming it further made the
            // divider nearly invisible against a dark background.
            return MarkdownRoleStyle()
        // Markers deliberately keep the body metrics. Changing their size
        // would reflow the line every time the caret moves on or off it,
        // which is the jitter that makes reveal-on-caret-line unusable.
        case .headingMarker, .emphasisMarker, .blockQuoteMarker, .listMarker,
             .linkMarker, .imageMarker, .wikiLinkMarker, .escape:
            return MarkdownRoleStyle()
        case .taskMarkerUnchecked, .taskMarkerChecked:
            return MarkdownRoleStyle(weight: .medium)
        }
    }
}

/// Whether the `**`, `#`, and `[]()` characters are shown.
enum MarkerVisibility: String, Codable, Sendable, CaseIterable {
    /// Always drawn at full strength.
    case always
    /// Dimmed, and restored to full strength on the line holding the caret.
    case caretLine
    /// Collapsed to zero width except on the caret line.
    case hidden
}
