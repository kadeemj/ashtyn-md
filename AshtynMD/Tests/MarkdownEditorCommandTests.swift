import AppKit
import Testing

@testable import AshtynMD

/// End-to-end command tests: the pure transforms are covered in
/// MarkdownTransformTests, so these assert the adapter layer — undo grouping,
/// caret placement, and that the commands decline on a code document.
@Suite("Markdown editor commands")
@MainActor
struct MarkdownEditorCommandTests {
    private func makeEditor(
        _ text: String,
        caret: Int? = nil,
        selection: NSRange? = nil,
        language: LanguageID = .markdown
    ) -> PlainTextView {
        let view = PlainTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.allowsUndo = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = view
        view.languageDefinition = LanguageDefinition.definition(for: language)
        view.profile = EditorProfile.defaultProfile(for: language)
        view.string = text
        if let selection {
            view.setSelectedRange(selection)
        } else if let caret {
            view.setSelectedRange(NSRange(location: caret, length: 0))
        }
        return view
    }

    // MARK: - Inline

    @Test("bold wraps the selection")
    func bold() {
        let view = makeEditor("make this bold", selection: NSRange(location: 5, length: 4))
        view.toggleMarkdownBold(nil)
        #expect(view.string == "make **this** bold")
        #expect(view.selectedRange() == NSRange(location: 7, length: 4))
    }

    @Test("bold is undoable in one step")
    func boldUndo() {
        let view = makeEditor("make this bold", selection: NSRange(location: 5, length: 4))
        view.toggleMarkdownBold(nil)
        view.undoManager?.undo()
        #expect(view.string == "make this bold")
    }

    @Test("bold toggles back off")
    func boldRoundTrip() {
        let view = makeEditor("make this bold", selection: NSRange(location: 5, length: 4))
        view.toggleMarkdownBold(nil)
        view.toggleMarkdownBold(nil)
        #expect(view.string == "make this bold")
    }

    @Test("italic, code, and strikethrough all apply")
    func otherInlineStyles() {
        let italic = makeEditor("word", selection: NSRange(location: 0, length: 4))
        italic.toggleMarkdownItalic(nil)
        #expect(italic.string == "_word_")

        let code = makeEditor("word", selection: NSRange(location: 0, length: 4))
        code.toggleMarkdownInlineCode(nil)
        #expect(code.string == "`word`")

        let struck = makeEditor("word", selection: NSRange(location: 0, length: 4))
        struck.toggleMarkdownStrikethrough(nil)
        #expect(struck.string == "~~word~~")
    }

    @Test("a link uses a URL from the pasteboard")
    func linkFromPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://example.com", forType: .string)
        let view = makeEditor("see docs", selection: NSRange(location: 4, length: 4))
        view.insertMarkdownLink(nil)
        #expect(view.string == "see [docs](https://example.com)")
    }

    @Test("a link ignores non-URL pasteboard content")
    func linkIgnoresProse() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("some prose", forType: .string)
        let view = makeEditor("see docs", selection: NSRange(location: 4, length: 4))
        view.insertMarkdownLink(nil)
        #expect(view.string == "see [docs]()")
    }

    // MARK: - Headings

    @Test("headings apply and toggle off")
    func headings() {
        let view = makeEditor("Title", caret: 0)
        view.setMarkdownHeading1(nil)
        #expect(view.string == "# Title")
        view.setMarkdownHeading1(nil)
        #expect(view.string == "Title")
    }

    @Test("each heading level has its own command")
    func headingLevels() {
        let view = makeEditor("Title", caret: 0)
        view.setMarkdownHeading2(nil)
        #expect(view.string == "## Title")
        view.setMarkdownHeading5(nil)
        #expect(view.string == "##### Title")
        view.clearMarkdownBlockStyle(nil)
        #expect(view.string == "Title")
    }

    // MARK: - Blocks

    @Test("quote, lists, and divider apply")
    func blockCommands() {
        let quote = makeEditor("line", caret: 0)
        quote.toggleMarkdownQuote(nil)
        #expect(quote.string == "> line")

        let bullets = makeEditor("a\nb", selection: NSRange(location: 0, length: 3))
        bullets.toggleMarkdownBulletList(nil)
        #expect(bullets.string == "- a\n- b")

        let numbers = makeEditor("a\nb", selection: NSRange(location: 0, length: 3))
        numbers.toggleMarkdownNumberedList(nil)
        #expect(numbers.string == "1. a\n2. b")

        let divider = makeEditor("above\nbelow", caret: 5)
        divider.insertMarkdownDivider(nil)
        #expect(divider.string == "above\n\n---\n\nbelow")
    }

    @Test("todo cycles through unchecked and checked")
    func todo() {
        let view = makeEditor("buy milk", caret: 0)
        view.toggleMarkdownTask(nil)
        #expect(view.string == "- [ ] buy milk")
        view.toggleMarkdownTask(nil)
        #expect(view.string == "- [x] buy milk")
        view.toggleMarkdownTask(nil)
        #expect(view.string == "- [ ] buy milk")
    }

    @Test("a multi-line todo toggle is one undo step")
    func multiLineTodoUndo() {
        let view = makeEditor("a\nb\nc", selection: NSRange(location: 0, length: 5))
        view.toggleMarkdownTask(nil)
        #expect(view.string == "- [ ] a\n- [ ] b\n- [ ] c")
        view.undoManager?.undo()
        #expect(view.string == "a\nb\nc")
    }

    // MARK: - Language guard

    @Test("formatting commands do nothing in a code document")
    func codeDocumentsAreUntouched() {
        let view = makeEditor("let x = 1", selection: NSRange(location: 4, length: 1), language: .swift)
        view.toggleMarkdownBold(nil)
        view.setMarkdownHeading1(nil)
        view.toggleMarkdownTask(nil)
        view.insertMarkdownDivider(nil)
        #expect(view.string == "let x = 1")
    }

    // MARK: - Checkbox clicking

    @Test("the task marker exposes its bracket range for hit testing")
    func taskMarkerBracketRange() {
        let text = "- [ ] milk\n- [x] eggs"
        let markers = MarkdownTasks.markers(in: text)
        #expect(markers.count == 2)
        #expect((text as NSString).substring(with: markers[0].bracketRange) == "[ ]")
        #expect((text as NSString).substring(with: markers[1].bracketRange) == "[x]")
        #expect((text as NSString).substring(with: markers[0].lineRange) == "- [ ] milk\n")
    }

    @Test("toggling a checkbox from the preview path still works")
    func previewTogglePathUnchanged() {
        let text = "- [ ] milk\n- [x] eggs"
        let edit = MarkdownTasks.toggleEdit(forTaskAt: 1, in: text)
        #expect(edit?.replacement == " ")
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit!.range, with: edit!.replacement)
        #expect(result as String == "- [ ] milk\n- [ ] eggs")
    }

    // MARK: - Modes

    @Test("mode commands route through the handler")
    func modeHandler() {
        let view = makeEditor("# Note", caret: 0)
        var received: [MarkdownEditorMode] = []
        view.markdownModeToggleHandler = { received.append($0) }

        view.toggleFocusMode(nil)
        view.toggleTypewriterMode(nil)
        view.cycleMarkerVisibility(nil)
        #expect(received == [.focus, .typewriter, .markerVisibility])
    }

    @Test("mode commands are inert in a code document")
    func modeHandlerCodeGuard() {
        let view = makeEditor("let x = 1", caret: 0, language: .swift)
        var received: [MarkdownEditorMode] = []
        view.markdownModeToggleHandler = { received.append($0) }
        view.toggleFocusMode(nil)
        #expect(received.isEmpty)
    }
}

extension MarkdownEditorMode: Equatable {}
