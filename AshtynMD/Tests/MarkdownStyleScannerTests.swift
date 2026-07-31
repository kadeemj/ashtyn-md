import Foundation
import Testing

@testable import AshtynMD

@Suite("Markdown style scanner")
struct MarkdownStyleScannerTests {
    private func scan(_ text: String) -> MarkdownStyleResult {
        MarkdownStyleScanner.scan(text as NSString)
    }

    private func spans(_ text: String, _ role: MarkdownStyleRole) -> [String] {
        let nsText = text as NSString
        return scan(text).spans
            .filter { $0.role == role }
            .map { nsText.substring(with: $0.range) }
    }

    private func blocks(_ text: String) -> [MarkdownBlockKind] {
        scan(text).blocks.map(\.kind)
    }

    // MARK: - Headings

    @Test("ATX headings carry their level")
    func atxHeadingLevels() {
        for level in 1...6 {
            let text = String(repeating: "#", count: level) + " Title"
            let heading = scan(text).spans.first { $0.role == .heading }
            #expect(heading?.level == level, "level \(level)")
            #expect(blocks(text) == [.heading(level)])
        }
    }

    @Test("the heading marker is a separate span from the heading text")
    func headingMarkerIsSeparate() {
        #expect(spans("## Title", .headingMarker) == ["## "])
        #expect(spans("## Title", .heading) == ["Title"])
    }

    @Test("seven hashes is not a heading")
    func sevenHashesIsNotAHeading() {
        #expect(spans("####### Nope", .heading) == [])
    }

    @Test("setext headings are recognized")
    func setextHeadings() {
        #expect(blocks("Title\n=====") == [.heading(1), .heading(1)])
        #expect(blocks("Title\n-----") == [.heading(2), .heading(2)])
    }

    // MARK: - Inline emphasis

    @Test("bold, italic, and bold-italic are distinguished")
    func emphasis() {
        #expect(spans("**bold**", .bold) == ["bold"])
        #expect(spans("*italic*", .italic) == ["italic"])
        #expect(spans("_italic_", .italic) == ["italic"])
        #expect(spans("***both***", .boldItalic) == ["both"])
    }

    @Test("emphasis markers are their own spans")
    func emphasisMarkers() {
        #expect(spans("**bold**", .emphasisMarker) == ["**", "**"])
    }

    @Test("strikethrough is recognized")
    func strikethrough() {
        #expect(spans("~~gone~~", .strikethrough) == ["gone"])
    }

    @Test("intraword underscores are not emphasis")
    func intrawordUnderscore() {
        #expect(spans("snake_case_name", .italic) == [])
    }

    @Test("emphasis does not span a blank line")
    func emphasisDoesNotSpanBlankLine() {
        #expect(spans("**start\n\nend**", .bold) == [])
    }

    @Test("unmatched delimiters produce no emphasis")
    func unmatchedDelimiters() {
        #expect(spans("**not closed", .bold) == [])
        #expect(spans("2 * 3 * 4", .italic) == [])
    }

    @Test("backslash escapes suppress emphasis")
    func escapes() {
        #expect(spans("\\*not italic\\*", .italic) == [])
        #expect(spans("\\*escaped\\*", .escape).count == 2)
    }

    // MARK: - Code

    @Test("inline code masks emphasis inside it")
    func inlineCodeMasksEmphasis() {
        #expect(spans("`a *b* c`", .inlineCode) == ["a *b* c"])
        #expect(spans("`a *b* c`", .italic) == [])
    }

    @Test("a doubled backtick run needs a doubled closer")
    func doubledBacktickRun() {
        #expect(spans("``a ` b``", .inlineCode) == ["a ` b"])
    }

    @Test("fenced code blocks are tagged, including the info string")
    func fencedCode() {
        let text = """
        ```swift
        let x = 1
        ```
        """
        #expect(spans(text, .codeInfoString) == ["swift"])
        #expect(spans(text, .codeFence) == ["```", "```"])
        #expect(spans(text, .codeBlock) == ["let x = 1"])
        #expect(blocks(text) == [.codeBlock, .codeBlock, .codeBlock])
    }

    @Test("an unclosed fence runs to the end of the document")
    func unclosedFence() {
        #expect(blocks("```\ncode\nmore") == [.codeBlock, .codeBlock, .codeBlock])
    }

    // MARK: - Blocks

    @Test("blockquote depth is counted")
    func blockquoteDepth() {
        #expect(blocks("> one") == [.blockQuote(depth: 1)])
        #expect(blocks("> > two") == [.blockQuote(depth: 2)])
        #expect(blocks(">> two") == [.blockQuote(depth: 2)])
    }

    @Test("list markers carry depth and ordering")
    func listMarkers() {
        #expect(blocks("- a") == [.listItem(depth: 0, ordered: false, task: false)])
        #expect(blocks("  - a") == [.listItem(depth: 1, ordered: false, task: false)])
        #expect(blocks("    - a") == [.listItem(depth: 2, ordered: false, task: false)])
        #expect(blocks("1. a") == [.listItem(depth: 0, ordered: true, task: false)])
        #expect(blocks("1) a") == [.listItem(depth: 0, ordered: true, task: false)])
        #expect(spans("- a", .listMarker) == ["- "])
    }

    @Test("task markers are distinguished by checked state")
    func taskMarkers() {
        #expect(blocks("- [ ] todo") == [.listItem(depth: 0, ordered: false, task: true)])
        #expect(spans("- [ ] todo", .taskMarkerUnchecked) == ["[ ]"])
        #expect(spans("- [x] done", .taskMarkerChecked) == ["[x]"])
        #expect(spans("- [X] done", .taskMarkerChecked) == ["[X]"])
    }

    @Test("task bracket ranges are exported for hit testing")
    func taskBracketRanges() {
        let text = "- [ ] a\n- [x] b"
        let nsText = text as NSString
        let ranges = scan(text).taskBracketRanges
        #expect(ranges.map { nsText.substring(with: $0) } == ["[ ]", "[x]"])
    }

    @Test("thematic breaks are recognized")
    func thematicBreak() {
        #expect(blocks("---") == [.thematicBreak])
        #expect(blocks("***") == [.thematicBreak])
        #expect(blocks("___") == [.thematicBreak])
        #expect(blocks("- - -") == [.thematicBreak])
    }

    @Test("blank lines are their own block kind")
    func blankLines() {
        #expect(blocks("a\n\nb") == [.paragraph, .blank, .paragraph])
    }

    @Test("content column marks where the text starts after a marker")
    func contentColumn() {
        let result = scan("  - item")
        #expect(result.blocks[0].contentColumn == 4)
        #expect(scan("> quoted").blocks[0].contentColumn == 2)
        #expect(scan("### Head").blocks[0].contentColumn == 4)
    }

    // MARK: - Links, images, tags

    @Test("links split into text, url, and markers")
    func links() {
        #expect(spans("[label](https://example.com)", .linkText) == ["label"])
        #expect(spans("[label](https://example.com)", .linkURL) == ["https://example.com"])
    }

    @Test("images are marked")
    func images() {
        #expect(spans("![alt](pic.png)", .imageMarker) == ["!"])
        #expect(spans("![alt](pic.png)", .linkURL) == ["pic.png"])
    }

    @Test("autolinks are recognized")
    func autolinks() {
        #expect(spans("<https://example.com>", .autolink) == ["https://example.com"])
    }

    @Test("wiki links are recognized")
    func wikiLinks() {
        #expect(spans("see [[Other Note]] there", .wikiLink) == ["Other Note"])
        #expect(spans("see [[Other Note]] there", .wikiLinkMarker) == ["[[", "]]"])
    }

    @Test("tags become spans and are exported separately")
    func tags() {
        let text = "note #work/alpha here"
        let nsText = text as NSString
        let result = scan(text)
        #expect(result.spans.filter { $0.role == .tag }.map { nsText.substring(with: $0.range) }
            == ["#work/alpha"])
        #expect(result.tagRanges.map { nsText.substring(with: $0) } == ["#work/alpha"])
    }

    @Test("front matter is one span")
    func frontMatter() {
        let text = "---\ntitle: x\n---\nbody"
        #expect(spans(text, .frontMatter) == ["---\ntitle: x\n---"])
    }

    // MARK: - Incrementality

    @Test("a ranged scan matches the full scan restricted to that range")
    func rangedScanMatchesFullScan() {
        let text = """
        # Title

        Some **bold** and `code` and #tag.

        - [ ] todo item
        - [x] done item

        ```swift
        let x = 1
        ```

        > quoted **text**
        """
        let nsText = text as NSString
        let full = MarkdownStyleScanner.scan(nsText)

        // Every block boundary is a legal restart point.
        for block in full.blocks {
            let fenceState = MarkdownStyleScanner.fenceState(of: nsText, atLineStartingAt: block.lineRange.location)
            let partial = MarkdownStyleScanner.scan(
                nsText,
                in: block.lineRange,
                fenceState: fenceState
            )
            let expected = full.spans.filter { NSIntersectionRange($0.range, block.lineRange).length > 0 }
            #expect(
                partial.spans.map(\.range.location) == expected.map(\.range.location),
                "mismatch at \(nsText.substring(with: block.lineRange))"
            )
            #expect(partial.spans.map(\.role) == expected.map(\.role))
        }
    }

    @Test("a scan starting inside a fence is told so by fenceState")
    func fenceStateCarriesAcrossRanges() {
        let text = "```\n#nottag\n```\n#tag"
        let nsText = text as NSString
        let insideFence = (text as NSString).range(of: "#nottag")
        #expect(MarkdownStyleScanner.fenceState(of: nsText, atLineStartingAt: insideFence.location))

        let partial = MarkdownStyleScanner.scan(nsText, in: insideFence, fenceState: true)
        #expect(partial.tagRanges.isEmpty)
        #expect(partial.spans.contains { $0.role == .codeBlock })
    }

    // MARK: - Performance shape

    @Test("scanning is linear enough for a large document")
    func largeDocument() {
        let paragraph = """
        # Heading

        Some **bold** text with `code`, a [link](https://example.com), and #a/tag.

        - [ ] one
        - [x] two

        """
        let text = String(repeating: paragraph, count: 400) as NSString
        let result = MarkdownStyleScanner.scan(text)
        #expect(result.tagRanges.count == 400)
        #expect(result.taskBracketRanges.count == 800)
    }
}
