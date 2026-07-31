import Foundation
import Testing

@testable import AshtynMD

@Suite("Markdown transforms")
struct MarkdownTransformTests {
    /// Applies an edit and returns the resulting text with `|` marking the
    /// caret, or `[...]` marking a selection, so expectations read as text.
    private func apply(_ edit: TextEdit?, to text: String) -> String {
        guard let edit else { return "<nil>" }
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.range, with: edit.replacement)
        let selection = edit.selection
        if selection.length == 0 {
            result.insert("|", at: selection.location)
        } else {
            result.insert("]", at: NSMaxRange(selection))
            result.insert("[", at: selection.location)
        }
        return result as String
    }

    private func toggle(
        _ style: MarkdownInlineStyle,
        _ text: String,
        _ selection: NSRange
    ) -> String {
        apply(
            MarkdownInlineTransform.toggle(style, in: text as NSString, selection: selection),
            to: text
        )
    }

    // MARK: - Inline: wrapping

    @Test("a selection is wrapped and the inner content stays selected")
    func wrapSelection() {
        #expect(toggle(.bold, "make this bold", NSRange(location: 5, length: 4)) == "make **[this]** bold")
        #expect(toggle(.italic, "make this bold", NSRange(location: 5, length: 4)) == "make _[this]_ bold")
        #expect(toggle(.inlineCode, "make this bold", NSRange(location: 5, length: 4)) == "make `[this]` bold")
        #expect(
            toggle(.strikethrough, "make this bold", NSRange(location: 5, length: 4))
                == "make ~~[this]~~ bold"
        )
    }

    @Test("a caret inside a word wraps the whole word")
    func wrapWordAtCaret() {
        #expect(toggle(.bold, "make this bold", NSRange(location: 7, length: 0)) == "make **[this]** bold")
    }

    @Test("a caret in whitespace inserts an empty pair with the caret between")
    func emptyPair() {
        #expect(toggle(.bold, "a  b", NSRange(location: 2, length: 0)) == "a **|** b")
    }

    @Test("leading and trailing whitespace is pushed outside the delimiters")
    func whitespaceOutsideDelimiters() {
        // `**word **` is not valid strong emphasis, so the space has to move.
        #expect(toggle(.bold, "one two three", NSRange(location: 3, length: 5)) == "one **[two]** three")
    }

    // MARK: - Inline: unwrapping

    @Test("a selection exactly covering an existing run removes the delimiters")
    func unwrapExactSelection() {
        #expect(toggle(.bold, "a **word** b", NSRange(location: 4, length: 4)) == "a [word] b")
    }

    @Test("a caret inside an existing run removes the delimiters")
    func unwrapAtCaret() {
        #expect(toggle(.bold, "a **word** b", NSRange(location: 6, length: 0)) == "a [word] b")
        #expect(toggle(.italic, "a _word_ b", NSRange(location: 5, length: 0)) == "a [word] b")
        #expect(toggle(.inlineCode, "a `word` b", NSRange(location: 5, length: 0)) == "a [word] b")
    }

    @Test("toggling bold does not unwrap an italic run")
    func stylesAreIndependent() {
        let result = toggle(.bold, "a _word_ b", NSRange(location: 3, length: 4))
        #expect(result == "a _**[word]**_ b")
    }

    @Test("bold inside a bold-italic run is recognized")
    func boldInsideBoldItalic() {
        #expect(toggle(.italic, "a *word* b", NSRange(location: 5, length: 0)) == "a [word] b")
    }

    // MARK: - Inline: multi-line

    @Test("a multi-line selection wraps each line separately")
    func multiLineWrapsPerLine() {
        // CommonMark emphasis cannot straddle a line break, so one pair around
        // the whole selection would silently fail to render.
        let text = "one\ntwo\nthree"
        let edit = MarkdownInlineTransform.toggle(
            .bold, in: text as NSString, selection: NSRange(location: 0, length: 13)
        )
        #expect(edit?.replacement == "**one**\n**two**\n**three**")
    }

    @Test("a multi-line selection skips blank lines")
    func multiLineSkipsBlanks() {
        let text = "one\n\ntwo"
        let edit = MarkdownInlineTransform.toggle(
            .bold, in: text as NSString, selection: NSRange(location: 0, length: 8)
        )
        #expect(edit?.replacement == "**one**\n\n**two**")
    }

    // MARK: - Links

    private func link(_ text: String, _ selection: NSRange, clipboard: String?) -> String {
        apply(
            MarkdownInlineTransform.link(
                in: text as NSString, selection: selection, clipboardURL: clipboard
            ),
            to: text
        )
    }

    @Test("an empty selection with a clipboard URL leaves the caret in the label")
    func linkEmptyWithURL() {
        #expect(
            link("say ", NSRange(location: 4, length: 0), clipboard: "https://example.com")
                == "say [|](https://example.com)"
        )
    }

    @Test("an empty selection without a URL leaves the caret in the label")
    func linkEmptyWithoutURL() {
        #expect(link("say ", NSRange(location: 4, length: 0), clipboard: nil) == "say [|]()")
    }

    @Test("a selection with a clipboard URL becomes a finished link")
    func linkSelectionWithURL() {
        #expect(
            link("see docs here", NSRange(location: 4, length: 4), clipboard: "https://x.dev")
                == "see [docs](https://x.dev)| here"
        )
    }

    @Test("a selection without a URL parks the caret in the destination")
    func linkSelectionWithoutURL() {
        #expect(
            link("see docs here", NSRange(location: 4, length: 4), clipboard: nil)
                == "see [docs](|) here"
        )
    }

    @Test("only URL-shaped clipboard content is used")
    func linkIgnoresNonURLClipboard() {
        #expect(link("a ", NSRange(location: 2, length: 0), clipboard: "just words") == "a [|]()")
        #expect(link("a ", NSRange(location: 2, length: 0), clipboard: "www.x.dev") == "a [|](www.x.dev)")
        #expect(link("a ", NSRange(location: 2, length: 0), clipboard: "mailto:a@b.c") == "a [|](mailto:a@b.c)")
    }

    @Test("a caret inside an existing link unwraps it to the label")
    func linkUnwrap() {
        #expect(
            link("see [docs](https://x.dev) now", NSRange(location: 7, length: 0), clipboard: nil)
                == "see [docs] now"
        )
    }

    // MARK: - Headings

    private func heading(_ level: Int, _ text: String, _ selection: NSRange) -> String {
        apply(
            MarkdownBlockTransform.setHeading(level: level, in: text as NSString, selection: selection),
            to: text
        )
    }

    @Test("a heading level is applied to the caret's line")
    func applyHeading() {
        #expect(heading(1, "Title", NSRange(location: 0, length: 0)) == "[# Title]")
        #expect(heading(3, "Title", NSRange(location: 2, length: 0)) == "[### Title]")
    }

    @Test("applying the level a line already has strips it")
    func headingTogglesOff() {
        #expect(heading(2, "## Title", NSRange(location: 4, length: 0)) == "[Title]")
    }

    @Test("a different level replaces the existing one")
    func headingReplaces() {
        #expect(heading(4, "## Title", NSRange(location: 4, length: 0)) == "[#### Title]")
    }

    @Test("a heading keeps a blockquote marker but drops a list marker")
    func headingPreservesQuote() {
        let quoted = MarkdownBlockTransform.setHeading(
            level: 2, in: "> Quoted" as NSString, selection: NSRange(location: 3, length: 0)
        )
        #expect(quoted?.replacement == "> ## Quoted")

        let listed = MarkdownBlockTransform.setHeading(
            level: 2, in: "- Item" as NSString, selection: NSRange(location: 3, length: 0)
        )
        #expect(listed?.replacement == "## Item")
    }

    @Test("a heading applies across every selected line")
    func headingMultiLine() {
        let edit = MarkdownBlockTransform.setHeading(
            level: 2, in: "one\ntwo" as NSString, selection: NSRange(location: 0, length: 7)
        )
        #expect(edit?.replacement == "## one\n## two")
    }

    @Test("clearing block style removes headings, quotes, and list markers")
    func clearBlockStyle() {
        let cases = ["## Title", "> Title", "- Title", "1. Title", "- [ ] Title"]
        for input in cases {
            let edit = MarkdownBlockTransform.clearBlockStyle(
                in: input as NSString,
                selection: NSRange(location: input.count, length: 0)
            )
            #expect(edit?.replacement == "Title", "failed for \(input)")
        }
    }

    // MARK: - Quotes

    @Test("quoting adds a level and unquoting removes one")
    func toggleQuote() {
        let plain = MarkdownBlockTransform.toggleQuote(
            in: "line" as NSString, selection: NSRange(location: 0, length: 0)
        )
        #expect(plain?.replacement == "> line")

        let quoted = MarkdownBlockTransform.toggleQuote(
            in: "> line" as NSString, selection: NSRange(location: 0, length: 0)
        )
        #expect(quoted?.replacement == "line")
    }

    @Test("a mixed selection quotes everything rather than unquoting")
    func toggleQuoteMixed() {
        let edit = MarkdownBlockTransform.toggleQuote(
            in: "> one\ntwo" as NSString, selection: NSRange(location: 0, length: 9)
        )
        #expect(edit?.replacement == "> > one\n> two")
    }

    // MARK: - Lists

    @Test("bulleted list toggles on and off")
    func toggleBulletList() {
        let on = MarkdownBlockTransform.toggleList(
            ordered: false, in: "item" as NSString, selection: NSRange(location: 0, length: 0)
        )
        #expect(on?.replacement == "- item")

        let off = MarkdownBlockTransform.toggleList(
            ordered: false, in: "- item" as NSString, selection: NSRange(location: 0, length: 0)
        )
        #expect(off?.replacement == "item")
    }

    @Test("an ordered list numbers from one across the block")
    func orderedListNumbers() {
        let edit = MarkdownBlockTransform.toggleList(
            ordered: true, in: "a\nb\nc" as NSString, selection: NSRange(location: 0, length: 5)
        )
        #expect(edit?.replacement == "1. a\n2. b\n3. c")
    }

    @Test("switching list kind replaces the marker")
    func switchListKind() {
        let edit = MarkdownBlockTransform.toggleList(
            ordered: true, in: "- a\n- b" as NSString, selection: NSRange(location: 0, length: 7)
        )
        #expect(edit?.replacement == "1. a\n2. b")
    }

    // MARK: - Tasks

    @Test("a plain line becomes an unchecked task")
    func taskFromPlainLine() {
        let edit = MarkdownBlockTransform.toggleTask(
            in: "buy milk" as NSString, selection: NSRange(location: 0, length: 0)
        )
        #expect(edit?.replacement == "- [ ] buy milk")
    }

    @Test("a list item gains a checkbox without losing its marker")
    func taskFromListItem() {
        let edit = MarkdownBlockTransform.toggleTask(
            in: "- buy milk" as NSString, selection: NSRange(location: 0, length: 0)
        )
        #expect(edit?.replacement == "- [ ] buy milk")
    }

    @Test("an unchecked task becomes checked and back")
    func taskFlips() {
        let check = MarkdownBlockTransform.toggleTask(
            in: "- [ ] milk" as NSString, selection: NSRange(location: 0, length: 0)
        )
        #expect(check?.replacement == "- [x] milk")

        let uncheck = MarkdownBlockTransform.toggleTask(
            in: "- [x] milk" as NSString, selection: NSRange(location: 0, length: 0)
        )
        #expect(uncheck?.replacement == "- [ ] milk")
    }

    @Test("an all-checked selection unchecks, a mixed one checks")
    func taskMultiLine() {
        let allChecked = MarkdownBlockTransform.toggleTask(
            in: "- [x] a\n- [x] b" as NSString, selection: NSRange(location: 0, length: 15)
        )
        #expect(allChecked?.replacement == "- [ ] a\n- [ ] b")

        let mixed = MarkdownBlockTransform.toggleTask(
            in: "- [x] a\n- [ ] b" as NSString, selection: NSRange(location: 0, length: 15)
        )
        #expect(mixed?.replacement == "- [x] a\n- [x] b")
    }

    // MARK: - Divider

    @Test("a divider is inserted with one blank line either side")
    func divider() {
        #expect(
            apply(
                MarkdownBlockTransform.divider(
                    in: "above\nbelow" as NSString, selection: NSRange(location: 5, length: 0)
                ),
                to: "above\nbelow"
            ) == "above\n\n---\n\n|below"
        )
    }

    @Test("a divider does not stack extra blank lines")
    func dividerNormalizesBlanks() {
        let text = "above\n\n\nbelow"
        let edit = MarkdownBlockTransform.divider(
            in: text as NSString, selection: NSRange(location: 7, length: 0)
        )
        let result = apply(edit, to: text)
        #expect(!result.contains("\n\n\n\n"))
        #expect(result.contains("---"))
    }

    // MARK: - Indent

    @Test("indenting a list item shifts it and renumbers siblings")
    func indentListItem() {
        let edit = MarkdownBlockTransform.changeListIndent(
            by: 1,
            in: "- a\n- b" as NSString,
            selection: NSRange(location: 5, length: 0),
            indentUnit: "  "
        )
        #expect(edit?.replacement == "  - b")
    }

    @Test("outdenting stops at the left margin")
    func outdentFloor() {
        let edit = MarkdownBlockTransform.changeListIndent(
            by: -1,
            in: "- a" as NSString,
            selection: NSRange(location: 0, length: 0),
            indentUnit: "  "
        )
        #expect(edit == nil)
    }

    @Test("indent declines on a line that is not a list item")
    func indentNonList() {
        let edit = MarkdownBlockTransform.changeListIndent(
            by: 1,
            in: "plain text" as NSString,
            selection: NSRange(location: 0, length: 0),
            indentUnit: "  "
        )
        #expect(edit == nil)
    }

    // MARK: - Robustness

    @Test("transforms decline on an empty document rather than crashing")
    func emptyDocument() {
        let empty = "" as NSString
        let caret = NSRange(location: 0, length: 0)
        _ = MarkdownInlineTransform.toggle(.bold, in: empty, selection: caret)
        _ = MarkdownInlineTransform.link(in: empty, selection: caret, clipboardURL: nil)
        _ = MarkdownBlockTransform.setHeading(level: 1, in: empty, selection: caret)
        _ = MarkdownBlockTransform.toggleQuote(in: empty, selection: caret)
        _ = MarkdownBlockTransform.toggleList(ordered: false, in: empty, selection: caret)
        _ = MarkdownBlockTransform.toggleTask(in: empty, selection: caret)
        _ = MarkdownBlockTransform.divider(in: empty, selection: caret)
    }

    @Test("edits stay in range for a selection at the very end")
    func selectionAtEnd() {
        let text = "word"
        let edit = MarkdownInlineTransform.toggle(
            .bold, in: text as NSString, selection: NSRange(location: 4, length: 0)
        )
        #expect(edit != nil)
        if let edit {
            #expect(NSMaxRange(edit.range) <= (text as NSString).length)
        }
    }
}
