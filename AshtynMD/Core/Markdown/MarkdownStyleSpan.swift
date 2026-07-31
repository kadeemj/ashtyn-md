import Foundation

/// What a run of Markdown source *is*, independent of how it looks.
///
/// The editor maps these to fonts and colors; nothing here knows about AppKit,
/// which is what lets the scanner be unit-tested without a text view.
enum MarkdownStyleRole: String, Codable, Sendable, CaseIterable, Hashable {
    case heading
    case headingMarker
    case bold
    case italic
    case boldItalic
    case strikethrough
    case emphasisMarker
    case inlineCode
    case inlineCodeMarker
    case codeBlock
    case codeFence
    case codeInfoString
    case blockQuote
    case blockQuoteMarker
    case listMarker
    case taskMarkerUnchecked
    case taskMarkerChecked
    case linkText
    case linkURL
    case linkMarker
    case autolink
    case imageMarker
    case wikiLink
    case wikiLinkMarker
    case tag
    case thematicBreak
    case escape
    case frontMatter
}

/// A styled run. `level` carries heading level, quote depth, list depth, or
/// tag depth depending on the role, and is 0 where it has no meaning.
struct MarkdownStyleSpan: Sendable, Equatable, Hashable {
    let range: NSRange
    let role: MarkdownStyleRole
    let level: Int

    init(range: NSRange, role: MarkdownStyleRole, level: Int = 0) {
        self.range = range
        self.role = role
        self.level = level
    }
}

enum MarkdownBlockKind: Sendable, Equatable, Hashable {
    case paragraph
    case heading(Int)
    case listItem(depth: Int, ordered: Bool, task: Bool)
    case blockQuote(depth: Int)
    case codeBlock
    case thematicBreak
    case frontMatter
    case blank
}

/// One line, classified. Drives paragraph style: indent, spacing, and the
/// hanging indent that makes wrapped list text line up under its content.
struct MarkdownBlockStyle: Sendable, Equatable, Hashable {
    /// Line content, excluding the terminator.
    let lineRange: NSRange
    let kind: MarkdownBlockKind
    /// UTF-16 offset within the line where content begins, after any marker.
    let contentColumn: Int
}

struct MarkdownStyleResult: Sendable, Equatable {
    var spans: [MarkdownStyleSpan] = []
    var blocks: [MarkdownBlockStyle] = []
    /// Full tag spans, including the leading `#`. Consumed by the pill drawing
    /// in the editor, which needs ranges rather than styled runs.
    var tagRanges: [NSRange] = []
    /// `[ ]` / `[x]` spans, for click hit-testing.
    var taskBracketRanges: [NSRange] = []
}
