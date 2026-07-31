import AppKit

/// Turns scanner roles and block kinds into AppKit attributes.
///
/// Kept free of any text-view reference so the mapping from role to font,
/// color, and paragraph style is unit-testable on its own.
struct MarkdownAttributeBuilder {
    let profile: EditorProfile
    let palette: EditorPalette

    /// Points of indent per list or quote level.
    private static let indentUnit: CGFloat = 18
    /// Extra padding either side of a tag, applied as kerning on the first and
    /// last character so the pill has room without inserting characters.
    static let tagKerning: CGFloat = 3

    private var baseFont: NSFont {
        Self.font(named: profile.fontFamily, size: profile.fontSize)
    }

    private var monospaceFont: NSFont {
        Self.font(named: profile.monospaceFontFamily, size: profile.fontSize)
    }

    /// Resolves a family name to a font.
    ///
    /// The San Francisco faces are not installed under their marketing names,
    /// so `NSFont(name: "SF Mono", size:)` returns nil and a naive fallback
    /// silently hands back the proportional system font — which would make
    /// code spans indistinguishable from prose. These aliases route to the
    /// system APIs that actually produce them.
    static func font(named family: String, size: Double) -> NSFont {
        switch family {
        case "SF Mono", "SFMono-Regular", "Monospace":
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case "SF Pro", "SF Pro Text", "SF Pro Display", "System":
            return .systemFont(ofSize: size)
        default:
            return NSFont(name: family, size: size)
                ?? .systemFont(ofSize: size)
        }
    }

    // MARK: - Base

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: palette.foreground.nsColor,
            .paragraphStyle: paragraphStyle(for: nil),
            .kern: 0,
            .underlineStyle: 0,
            .strikethroughStyle: 0,
        ]
    }

    // MARK: - Blocks

    func paragraphStyle(for block: MarkdownBlockStyle?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = profile.lineHeightMultiple
        style.paragraphSpacing = profile.paragraphSpacing
        // Deliberately no minimumLineHeight: a global floor would clamp the
        // taller line boxes that headings need.
        style.defaultTabInterval = tabInterval
        style.tabStops = []
        if !profile.wrapsLines {
            style.lineBreakMode = .byClipping
        }

        guard let block else { return style }

        switch block.kind {
        case .heading(let level):
            style.paragraphSpacingBefore = profile.fontSize * (level <= 2 ? 0.9 : 0.6)
            style.paragraphSpacing = profile.paragraphSpacing * 0.5
        case .listItem(let depth, _, _):
            // headIndent aligns wrapped text under the content, not the marker.
            style.firstLineHeadIndent = CGFloat(depth) * Self.indentUnit
            style.headIndent = CGFloat(depth) * Self.indentUnit
                + CGFloat(block.contentColumn) * approximateCharacterWidth
            style.paragraphSpacing = profile.paragraphSpacing * 0.25
        case .blockQuote(let depth):
            style.firstLineHeadIndent = CGFloat(depth) * Self.indentUnit
            style.headIndent = CGFloat(depth) * Self.indentUnit
        case .codeBlock:
            style.firstLineHeadIndent = Self.indentUnit * 0.5
            style.headIndent = Self.indentUnit * 0.5
            style.paragraphSpacing = 0
            style.lineHeightMultiple = 1.2
        case .thematicBreak, .frontMatter, .blank, .paragraph:
            break
        }
        return style
    }

    /// Width of a space in the base font, used to convert a marker's character
    /// column into points for the hanging indent.
    private var approximateCharacterWidth: CGFloat {
        let attributed = NSAttributedString(string: " ", attributes: [.font: baseFont])
        let width = attributed.size().width
        return width > 0 ? width : profile.fontSize * 0.5
    }

    private var tabInterval: CGFloat {
        approximateCharacterWidth * CGFloat(max(1, profile.tabWidth))
    }

    // MARK: - Inline roles

    /// Attributes for one styled run. `revealed` is true when the run sits on
    /// the caret line, which controls how strongly markers are drawn.
    func attributes(
        for span: MarkdownStyleSpan,
        revealed: Bool,
        headingLevel: Int
    ) -> [NSAttributedString.Key: Any] {
        let style = profile.roleStyle(for: span.role)
        var attributes: [NSAttributedString.Key: Any] = [:]

        let size: Double
        if span.role == .heading || span.role == .headingMarker {
            size = profile.headingSize(level: headingLevel > 0 ? headingLevel : span.level)
        } else {
            size = profile.fontSize * style.sizeMultiple
        }

        var font = style.isMonospaced
            ? Self.font(named: profile.monospaceFontFamily, size: size)
            : Self.font(named: profile.fontFamily, size: size)
        font = Self.applying(
            weight: style.weight, italic: style.isItalic, to: font, size: size
        )
        attributes[.font] = font

        var color = palette.color(for: span.role)
        if isMarker(span.role) {
            color = revealed || profile.markerVisibility == .always
                ? color
                : palette.markerDim
        }
        if style.opacity < 1 {
            color = color.blended(toward: palette.background, amount: 1 - style.opacity)
        }
        attributes[.foregroundColor] = color.nsColor

        if span.role == .strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if span.role == .linkText || span.role == .wikiLink || span.role == .autolink {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    /// Markers are the characters a Bear-like editor de-emphasizes: `**`, `#`,
    /// `[]()`, backticks, list bullets, and quote arrows.
    func isMarker(_ role: MarkdownStyleRole) -> Bool {
        switch role {
        case .headingMarker, .emphasisMarker, .inlineCodeMarker, .codeFence,
             .blockQuoteMarker, .linkMarker, .imageMarker, .wikiLinkMarker, .escape:
            return true
        default:
            return false
        }
    }

    static func applying(
        weight: MarkdownFontWeight,
        italic: Bool,
        to font: NSFont,
        size: Double
    ) -> NSFont {
        var descriptor = font.fontDescriptor
        if italic {
            descriptor = descriptor.withSymbolicTraits(
                descriptor.symbolicTraits.union(.italic)
            )
        }
        if weight != .regular {
            var traits = descriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any] ?? [:]
            traits[.weight] = weight.nsWeight.rawValue
            descriptor = descriptor.addingAttributes([.traits: traits])
        }
        // A descriptor can fail to resolve when the family lacks the face; fall
        // back to a synthesized system font rather than dropping the trait.
        if let resolved = NSFont(descriptor: descriptor, size: size) {
            return resolved
        }
        var fallback = NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
        if italic {
            let italicDescriptor = fallback.fontDescriptor.withSymbolicTraits(
                fallback.fontDescriptor.symbolicTraits.union(.italic)
            )
            fallback = NSFont(descriptor: italicDescriptor, size: size) ?? fallback
        }
        return fallback
    }
}
