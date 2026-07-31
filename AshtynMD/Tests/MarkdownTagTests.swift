import Foundation
import Testing

@testable import AshtynMD

@Suite("Markdown tags")
struct MarkdownTagTests {
    private func tags(_ text: String) -> [MarkdownTag] {
        MarkdownTagScanner.tags(in: text as NSString)
    }

    private func keys(_ text: String) -> [String] {
        tags(text).map(\.key)
    }

    // MARK: - The plain form

    @Test("a bare tag is recognized")
    func bareTag() {
        let found = tags("shopping list #groceries")
        #expect(found.count == 1)
        #expect(found[0].key == "groceries")
        #expect(found[0].path == "groceries")
        #expect(found[0].isClosingHashForm == false)
        #expect((("shopping list #groceries" as NSString).substring(with: found[0].range)) == "#groceries")
    }

    @Test("a tag at the very start of the text is recognized")
    func tagAtStart() {
        #expect(keys("#inbox capture this") == ["inbox"])
    }

    @Test("nesting splits on slashes")
    func nesting() {
        let found = tags("#work/alpha/beta")
        #expect(found.count == 1)
        #expect(found[0].key == "work/alpha/beta")
        #expect(found[0].components == ["work", "alpha", "beta"])
        #expect(found[0].depth == 3)
    }

    @Test("case is folded for the key but preserved for the path")
    func caseFolding() {
        let found = tags("#Work/Alpha")
        #expect(found[0].key == "work/alpha")
        #expect(found[0].path == "Work/Alpha")
    }

    @Test("a trailing slash is trimmed")
    func trailingSlash() {
        #expect(keys("#work/") == ["work"])
    }

    @Test(
        "trailing punctuation is trimmed",
        arguments: [
            ("see #work.", "work"),
            ("see #work,", "work"),
            ("see #work;", "work"),
            ("see #work:", "work"),
            ("see #work!", "work"),
            ("see #work?", "work"),
            ("(see #work)", "work"),
            ("[see #work]", "work"),
            ("see #work/alpha,", "work/alpha"),
        ]
    )
    func trailingPunctuation(input: String, expected: String) {
        #expect(keys(input) == [expected])
    }

    @Test("tags may open after a bracket or quote")
    func openingDelimiters() {
        #expect(keys("(#work)") == ["work"])
        #expect(keys("\"#work\"") == ["work"])
        #expect(keys("[#work]") == ["work"])
        #expect(keys("{#work}") == ["work"])
    }

    @Test("segment characters include dashes, underscores, plus, and dots")
    func segmentCharacters() {
        #expect(keys("#a-b_c+d.e") == ["a-b_c+d.e"])
    }

    @Test("multiple tags on one line are all found, in order")
    func multipleTags() {
        #expect(keys("#one and #two/sub and #three") == ["one", "two/sub", "three"])
    }

    // MARK: - Rejections

    @Test("an ATX heading is not a tag")
    func headingIsNotATag() {
        #expect(keys("# Heading") == [])
        #expect(keys("## Heading two") == [])
        #expect(keys("###### Heading six") == [])
    }

    @Test("a bare hash is not a tag")
    func bareHashIsNotATag() {
        #expect(keys("just a # on its own") == [])
        #expect(keys("#") == [])
    }

    @Test("a hash mid-word is not a tag")
    func midWordHashIsNotATag() {
        #expect(keys("C#") == [])
        #expect(keys("a#b") == [])
        #expect(keys("issue#12") == [])
    }

    @Test("numeric-only tags are rejected")
    func numericOnlyRejected() {
        #expect(keys("fixes #12345") == [])
        #expect(keys("#1") == [])
        // A leading digit is fine as long as the tag is not all digits.
        #expect(keys("#1password") == ["1password"])
    }

    @Test("an escaped hash is not a tag")
    func escapedHash() {
        #expect(keys("literal \\#notatag") == [])
    }

    @Test("a URL fragment is not a tag")
    func urlFragment() {
        #expect(keys("see https://example.com/page#section for details") == [])
    }

    // MARK: - Masked contexts

    @Test("tags inside inline code are ignored")
    func inlineCode() {
        #expect(keys("use `#define FOO` here") == [])
        #expect(keys("`#a` but #b counts") == ["b"])
    }

    @Test("tags inside fenced code blocks are ignored")
    func fencedCode() {
        let text = """
        real #tag here

        ```sh
        #!/bin/sh
        # not a tag
        #alsonotatag
        ```

        #after
        """
        #expect(keys(text) == ["tag", "after"])
    }

    @Test("tilde fences are honored")
    func tildeFence() {
        let text = """
        ~~~
        #hidden
        ~~~
        #visible
        """
        #expect(keys(text) == ["visible"])
    }

    @Test("tags inside YAML front matter are ignored")
    func frontMatter() {
        let text = """
        ---
        title: Something
        note: #notatag
        ---

        #real
        """
        #expect(keys(text) == ["real"])
    }

    @Test("front matter only counts at the very top of the file")
    func frontMatterOnlyAtTop() {
        let text = """
        Some prose first.

        ---
        #stillatag
        ---
        """
        #expect(keys(text) == ["stillatag"])
    }

    @Test("tags inside HTML comments are ignored")
    func htmlComment() {
        #expect(keys("<!-- #hidden --> #shown") == ["shown"])
    }

    @Test("tags inside link destinations are ignored")
    func linkDestination() {
        #expect(keys("[text](https://example.com/a#frag) and #real") == ["real"])
    }

    @Test("tags inside autolinks are ignored")
    func autolink() {
        #expect(keys("<https://example.com/a#frag> and #real") == ["real"])
    }

    @Test("link text is still scanned for tags")
    func linkTextIsScanned() {
        #expect(keys("[see #work](https://example.com)") == ["work"])
    }

    @Test("indented code blocks are a known false positive")
    func indentedCodeBlocksAreAKnownFalsePositive() {
        // Telling a 4-space indented code block apart from a list continuation
        // line needs a full CommonMark block parse. We accept a stray tag here
        // rather than risk dropping real tags written inside list items.
        let text = """
        Paragraph.

            #looks_like_code
        """
        #expect(keys(text) == ["looks_like_code"])
    }

    // MARK: - The closing-hash multi-word form

    @Test("a multi-word tag closed by a hash is recognized")
    func closingHashForm() {
        let found = tags("#multi word tag# rest")
        #expect(found.count == 1)
        #expect(found[0].key == "multi word tag")
        #expect(found[0].isClosingHashForm)
        #expect((("#multi word tag# rest" as NSString).substring(with: found[0].range)) == "#multi word tag#")
    }

    @Test("nesting works inside the closing-hash form")
    func closingHashNesting() {
        let found = tags("#work/big project# done")
        #expect(found[0].key == "work/big project")
        #expect(found[0].components == ["work", "big project"])
    }

    @Test("the closing-hash form requires an internal space")
    func closingHashRequiresSpace() {
        // Without the space rule `#a#b` would parse as one strange tag
        // spanning both hashes. With it, the multi-word form declines and the
        // ordinary scanner takes the leading tag as written.
        #expect(keys("#a#b") == ["a"])
        #expect(keys("#alpha#beta") == ["alpha"])
        #expect(tags("#a#b").allSatisfy { !$0.isClosingHashForm })
    }

    @Test("the closing hash must be on the same line")
    func closingHashSameLine() {
        let found = tags("#multi word\nstill going# no")
        #expect(found.map(\.key) == ["multi"])
        #expect(found.allSatisfy { !$0.isClosingHashForm })
    }

    @Test("the closing-hash form can be disabled")
    func closingHashOptional() {
        var options = MarkdownTagScanner.Options.default
        options.allowsClosingHashTags = false
        let found = MarkdownTagScanner.tags(in: "#multi word tag#" as NSString, options: options)
        // Falls back to the plain form rather than dropping the tag entirely,
        // so flipping the option is reversible with one reindex.
        #expect(found.map(\.key) == ["multi"])
        #expect(found.allSatisfy { !$0.isClosingHashForm })
    }

    // MARK: - Ranges

    @Test("ranges are UTF-16 correct across emoji")
    func emojiRanges() {
        let text = "🎉🎉 #party time"
        let found = tags(text)
        #expect(found.count == 1)
        #expect((text as NSString).substring(with: found[0].range) == "#party")
    }

    @Test("the closure includes every ancestor exactly once")
    func closure() {
        let closure = MarkdownTag.closure(for: tags("#work/alpha/beta and #work"))
        #expect(closure.map(\.key) == ["work", "work/alpha", "work/alpha/beta"])
        // #work is written directly and is also an ancestor: direct wins.
        #expect(closure.first { $0.key == "work" }?.isDirect == true)
        #expect(closure.first { $0.key == "work/alpha" }?.isDirect == false)
        #expect(closure.first { $0.key == "work/alpha/beta" }?.isDirect == true)
    }

    @Test("the closure preserves the display casing of the deepest write")
    func closureDisplayPath() {
        let closure = MarkdownTag.closure(for: tags("#Work/Alpha"))
        #expect(closure.first { $0.key == "work" }?.displayPath == "Work")
        #expect(closure.first { $0.key == "work/alpha" }?.displayPath == "Work/Alpha")
    }
}
