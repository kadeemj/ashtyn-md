import Foundation
import Markdown
import Testing

@testable import AshtynMD

/// Guards the one real cost of hand-writing the editor's scanner: the editor
/// and the WebKit preview now parse Markdown with different code. The preview
/// stays canonical (swift-markdown / cmark-gfm); this suite asserts the
/// scanner agrees with it about where the constructs are.
///
/// The corpus is deliberately ASCII-only. swift-markdown reports source
/// locations as 1-based line/column in UTF-8 code units, so ASCII lets us map
/// a location to a UTF-16 offset by simple arithmetic instead of reimplementing
/// cmark's column accounting inside a test.
@Suite("Markdown scanner parity")
struct MarkdownScannerParityTests {
    private static let corpus: [String] = [
        "# Heading one\n\nBody text.\n",
        "## Heading two\n\nSome **bold** and *italic* and ***both***.\n",
        "Text with `inline code` and a [link](https://example.com).\n",
        "> A quoted line.\n> A second quoted line.\n",
        "- first item\n- second item\n- [ ] a task\n- [x] a done task\n",
        "1. one\n2. two\n3. three\n",
        "```swift\nlet x = 1\n```\n",
        "Some ~~struck~~ text.\n",
        "A paragraph.\n\n---\n\nAnother paragraph.\n",
        "Nested **bold with `code` inside** here.\n",
        "![alt text](image.png)\n",
        "Setext heading\n==============\n\nBody.\n",
        """
        # Notes

        Mixed content with **bold**, `code`, a [link](https://example.com/a),
        and a list:

        - alpha
        - beta

        > quoted **bold**

        ```
        raw code *not emphasis*
        ```

        Done.

        """,
    ]

    /// Converts a swift-markdown source location to a UTF-16 offset.
    private func offset(of location: Markdown.SourceLocation, in source: MarkdownSource) -> Int? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < source.lineCount else { return nil }
        let line = source.line(lineIndex)
        let column = location.column - 1
        guard column >= 0 else { return nil }
        return min(line.location + column, NSMaxRange(line))
    }

    private func range(of markup: Markup, in source: MarkdownSource) -> NSRange? {
        guard let sourceRange = markup.range,
              let start = offset(of: sourceRange.lowerBound, in: source),
              let end = offset(of: sourceRange.upperBound, in: source),
              end > start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func walk(_ markup: Markup, _ visit: (Markup) -> Void) {
        visit(markup)
        for child in markup.children { walk(child, visit) }
    }

    @Test("every construct swift-markdown finds is styled by the scanner", arguments: corpus.indices)
    func parity(index: Int) {
        let text = Self.corpus[index]
        let nsText = text as NSString
        let source = MarkdownSource(nsText)
        let result = MarkdownStyleScanner.scan(nsText)
        let document = Document(parsing: text)

        func hasSpan(_ roles: Set<MarkdownStyleRole>, within range: NSRange) -> Bool {
            result.spans.contains { span in
                roles.contains(span.role) && NSIntersectionRange(span.range, range).length > 0
            }
        }

        func hasBlock(_ predicate: (MarkdownBlockKind) -> Bool, within range: NSRange) -> Bool {
            result.blocks.contains { block in
                predicate(block.kind) && NSIntersectionRange(block.lineRange, range).length > 0
            }
        }

        walk(document) { markup in
            guard let range = range(of: markup, in: source) else { return }
            let excerpt = nsText.substring(with: range)

            switch markup {
            case let heading as Heading:
                #expect(
                    hasSpan([.heading], within: range),
                    "heading not styled: \(excerpt)"
                )
                #expect(
                    hasBlock({ $0 == .heading(heading.level) }, within: range),
                    "heading level \(heading.level) missing for: \(excerpt)"
                )
            case is Strong:
                #expect(
                    hasSpan([.bold, .boldItalic], within: range),
                    "strong not styled: \(excerpt)"
                )
            case is Emphasis:
                #expect(
                    hasSpan([.italic, .boldItalic], within: range),
                    "emphasis not styled: \(excerpt)"
                )
            case is Strikethrough:
                #expect(
                    hasSpan([.strikethrough], within: range),
                    "strikethrough not styled: \(excerpt)"
                )
            case is InlineCode:
                #expect(
                    hasSpan([.inlineCode, .inlineCodeMarker], within: range),
                    "inline code not styled: \(excerpt)"
                )
            case is Link:
                #expect(
                    hasSpan([.linkText, .linkURL, .linkMarker, .autolink], within: range),
                    "link not styled: \(excerpt)"
                )
            case is Image:
                #expect(
                    hasSpan([.imageMarker, .linkURL, .linkText, .linkMarker], within: range),
                    "image not styled: \(excerpt)"
                )
            case is BlockQuote:
                #expect(
                    hasBlock({ if case .blockQuote = $0 { return true } else { return false } }, within: range),
                    "block quote not classified: \(excerpt)"
                )
            case is ListItem:
                #expect(
                    hasBlock({ if case .listItem = $0 { return true } else { return false } }, within: range),
                    "list item not classified: \(excerpt)"
                )
            case is CodeBlock:
                #expect(
                    hasBlock({ $0 == .codeBlock }, within: range),
                    "code block not classified: \(excerpt)"
                )
            case is ThematicBreak:
                #expect(
                    hasBlock({ $0 == .thematicBreak }, within: range),
                    "thematic break not classified: \(excerpt)"
                )
            default:
                break
            }
        }
    }

    @Test("the scanner does not style emphasis inside code that cmark treats as literal")
    func noEmphasisInsideCodeBlocks() {
        let text = "```\nraw *not emphasis* here\n```\n"
        let result = MarkdownStyleScanner.scan(text as NSString)
        #expect(!result.spans.contains { $0.role == .italic })
        #expect(!result.spans.contains { $0.role == .bold })
    }

    @Test("ordered and unordered list items agree with cmark on count")
    func listItemCount() {
        let text = "- a\n- b\n- c\n\n1. x\n2. y\n"
        let document = Document(parsing: text)
        var cmarkItems = 0
        walk(document) { if $0 is ListItem { cmarkItems += 1 } }

        let result = MarkdownStyleScanner.scan(text as NSString)
        let scannerItems = result.blocks.filter {
            if case .listItem = $0.kind { return true }
            return false
        }.count

        #expect(cmarkItems == 5)
        #expect(scannerItems == cmarkItems)
    }
}
