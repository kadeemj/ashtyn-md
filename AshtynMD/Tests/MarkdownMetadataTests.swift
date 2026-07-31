import Foundation
import Testing

@testable import AshtynMD

@Suite("Markdown metadata")
struct MarkdownMetadataTests {
    private func parse(_ text: String) -> ParsedNote {
        MarkdownMetadata.parse(text)
    }

    // MARK: - Title

    @Test("the first non-blank line is the title")
    func firstLineIsTitle() {
        #expect(parse("Groceries\n\nmilk\neggs").title == "Groceries")
    }

    @Test("leading blank lines are skipped")
    func leadingBlankLines() {
        #expect(parse("\n\n\nGroceries\nmilk").title == "Groceries")
    }

    @Test("heading markers are stripped from the title")
    func headingMarkersStripped() {
        #expect(parse("# Groceries").title == "Groceries")
        #expect(parse("### Deep heading").title == "Deep heading")
    }

    @Test("list, quote, and task markers are stripped from the title")
    func blockMarkersStripped() {
        #expect(parse("- Groceries").title == "Groceries")
        #expect(parse("* Groceries").title == "Groceries")
        #expect(parse("1. Groceries").title == "Groceries")
        #expect(parse("> Groceries").title == "Groceries")
        #expect(parse("- [ ] Buy milk").title == "Buy milk")
    }

    @Test("leading tags are stripped so the title is the prose")
    func leadingTagsStripped() {
        // The title becomes a filename, so "#work meeting notes" should be
        // named "meeting notes", not "#work meeting notes".
        #expect(parse("#work meeting notes\n\nbody").title == "meeting notes")
        #expect(parse("#work #urgent Standup\n").title == "Standup")
    }

    @Test("inline markup is flattened in the title")
    func inlineMarkupFlattened() {
        #expect(parse("**Bold** title").title == "Bold title")
        #expect(parse("A `code` title").title == "A code title")
        #expect(parse("[Linked](https://example.com) title").title == "Linked title")
        #expect(parse("A [[Wiki Note]] title").title == "A Wiki Note title")
        #expect(parse("*Italic* and ~~struck~~").title == "Italic and struck")
    }

    @Test("front matter is skipped when looking for the title")
    func frontMatterSkipped() {
        let text = """
        ---
        author: Kadeem
        ---
        Real Title

        body
        """
        #expect(parse(text).title == "Real Title")
    }

    @Test("a title made only of tags is empty")
    func tagOnlyTitle() {
        #expect(parse("#work #urgent").title == "")
        #expect(parse("").title == "")
        #expect(parse("\n\n").title == "")
    }

    @Test("whitespace is collapsed and the title is capped")
    func titleCollapsedAndCapped() {
        #expect(parse("A     spaced    title").title == "A spaced title")
        let long = String(repeating: "x", count: 400)
        #expect(parse(long).title.count == 120)
    }

    @Test("the title key folds case and whitespace")
    func titleKey() {
        #expect(parse("  Weekly   Review  ").titleKey == "weekly review")
        #expect(parse("# WEEKLY REVIEW").titleKey == "weekly review")
    }

    @Test("the title range points at the source line")
    func titleRange() {
        let text = "# Groceries\n\nmilk"
        let note = parse(text)
        #expect(note.titleRange != nil)
        #expect((text as NSString).substring(with: note.titleRange!) == "# Groceries")
    }

    // MARK: - Excerpt

    @Test("the excerpt is the body after the title")
    func excerpt() {
        #expect(parse("Title\nfirst body line\nsecond body line").excerpt
            == "first body line second body line")
    }

    @Test("the excerpt skips pure-tag lines and strips markers")
    func excerptSkipsTagLines() {
        let text = """
        Title
        #work #urgent
        - a bullet
        > a quote
        ## a heading
        """
        #expect(parse(text).excerpt == "a bullet a quote a heading")
    }

    @Test("fenced code contents are left out of the excerpt")
    func excerptSkipsCode() {
        let text = """
        Title
        before
        ```
        let secret = 1
        ```
        after
        """
        #expect(parse(text).excerpt == "before after")
    }

    @Test("the excerpt is capped")
    func excerptCapped() {
        let text = "Title\n" + String(repeating: "word ", count: 200)
        #expect(parse(text).excerpt.count <= 200)
    }

    @Test("a note with only a title has an empty excerpt")
    func emptyExcerpt() {
        #expect(parse("Just a title").excerpt == "")
    }

    // MARK: - Tags

    @Test("tags are collected in source order with duplicates retained")
    func tags() {
        let note = parse("Title\n\n#work and #home and #work again")
        #expect(note.tags.map(\.key) == ["work", "home", "work"])
    }

    @Test("the tag closure carries ancestors")
    func tagClosure() {
        let note = parse("Title\n\n#work/alpha/beta")
        #expect(note.tagClosure().map(\.key) == ["work", "work/alpha", "work/alpha/beta"])
        #expect(note.tagClosure().filter(\.isDirect).map(\.key) == ["work/alpha/beta"])
    }

    @Test("tags in the title line still count as tags")
    func titleLineTags() {
        let note = parse("#work meeting notes\n\nbody")
        #expect(note.tags.map(\.key) == ["work"])
        #expect(note.title == "meeting notes")
    }

    // MARK: - Wiki links

    @Test("wiki links are extracted with folded keys")
    func wikiLinks() {
        let note = parse("Title\n\nSee [[Weekly Review]] and [[Other]].")
        #expect(note.links.map(\.target) == ["Weekly Review", "Other"])
        #expect(note.links.map(\.key) == ["weekly review", "other"])
    }

    @Test("wiki link aliases are separated from the target")
    func wikiLinkAlias() {
        let note = parse("Title\n\n[[Weekly Review|last week]]")
        #expect(note.links.count == 1)
        #expect(note.links[0].target == "Weekly Review")
        #expect(note.links[0].alias == "last week")
        #expect(note.links[0].key == "weekly review")
    }

    @Test("wiki links inside code are ignored")
    func wikiLinksInCode() {
        #expect(parse("Title\n\n`[[Not A Link]]`").links.isEmpty)
        #expect(parse("Title\n\n```\n[[Not A Link]]\n```").links.isEmpty)
    }

    @Test("wiki link ranges cover the full brackets")
    func wikiLinkRanges() {
        let text = "Title\n\nSee [[Other Note]] here."
        let note = parse(text)
        #expect((text as NSString).substring(with: note.links[0].range) == "[[Other Note]]")
        #expect((text as NSString).substring(with: note.links[0].innerRange) == "Other Note")
    }

    // MARK: - Counts

    @Test("todo counts match the preview's task markers")
    func todoCountsMatchMarkdownTasks() {
        let text = """
        Title

        - [ ] open one
        - [x] done one
        - [ ] open two
        """
        let note = parse(text)
        // Reusing MarkdownTasks rather than a second regex is what keeps the
        // info panel's count from ever disagreeing with the preview's
        // checkbox indices.
        #expect(note.todoTotal == MarkdownTasks.markers(in: text).count)
        #expect(note.todoTotal == 3)
        #expect(note.todoOpen == 2)
    }

    @Test("word and character counts cover the body")
    func wordCount() {
        let note = parse("Title here\n\nfour more words now")
        #expect(note.wordCount == 6)
        #expect(note.characterCount == "Title here\n\nfour more words now".count)
    }

    @Test("CJK text counts one word per ideograph")
    func cjkWordCount() {
        // Without this, a note written in Chinese would report one word.
        let note = parse("标题\n\n这是一个测试")
        #expect(note.wordCount == 8)
    }

    @Test("reading time rounds up and is zero for an empty note")
    func readingTime() {
        #expect(parse("").readingTimeMinutes == 0)
        #expect(parse("Title\n\n" + String(repeating: "word ", count: 10)).readingTimeMinutes == 1)
        #expect(parse("Title\n\n" + String(repeating: "word ", count: 450)).readingTimeMinutes == 3)
    }

    @Test("front matter is excluded from the word count")
    func frontMatterNotCounted() {
        let text = """
        ---
        author: Someone Or Other
        ---
        Title

        body words here
        """
        #expect(parse(text).wordCount == 4)
    }

    // MARK: - Robustness

    @Test("parsing is stable on pathological input")
    func pathologicalInput() {
        _ = parse("")
        _ = parse("#")
        _ = parse("```")
        _ = parse("---")
        _ = parse("[[")
        _ = parse(String(repeating: "*", count: 500))
        _ = parse(String(repeating: "#", count: 500))
    }

    @Test("ranges stay UTF-16 correct with emoji in the title")
    func emojiTitle() {
        let text = "🎉 Party Plan\n\nbody"
        let note = parse(text)
        #expect(note.title == "🎉 Party Plan")
        #expect((text as NSString).substring(with: note.titleRange!) == "🎉 Party Plan")
    }
}
