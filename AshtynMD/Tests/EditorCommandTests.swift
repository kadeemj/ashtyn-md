import AppKit
import Testing
@testable import AshtynMD

/// Line-management and typing-helper tests against a real PlainTextView.
@Suite("Editor commands")
@MainActor
struct EditorCommandTests {
    private func makeEditor(
        _ text: String,
        caret: Int? = nil,
        selection: NSRange? = nil,
        language: LanguageID = .swift
    ) -> PlainTextView {
        let view = PlainTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isRichText = false
        view.allowsUndo = true
        // Undo support requires a window-provided undo manager.
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

    // MARK: - Duplicate

    @Test func duplicateMiddleLine() {
        let view = makeEditor("one\ntwo\nthree\n", caret: 5)
        view.duplicateLineOrSelection(nil)
        #expect(view.string == "one\ntwo\ntwo\nthree\n")
    }

    @Test func duplicateLastLineWithoutNewline() {
        let view = makeEditor("one\ntwo", caret: 6)
        view.duplicateLineOrSelection(nil)
        #expect(view.string == "one\ntwo\ntwo")
    }

    @Test func duplicateSelection() {
        let view = makeEditor("abcdef", selection: NSRange(location: 1, length: 3))
        view.duplicateLineOrSelection(nil)
        #expect(view.string == "abcdbcdef")
    }

    // MARK: - Delete line

    @Test func deleteMiddleLine() {
        let view = makeEditor("one\ntwo\nthree\n", caret: 5)
        view.deleteCurrentLines(nil)
        #expect(view.string == "one\nthree\n")
    }

    @Test func deleteLastLineWithoutNewline() {
        let view = makeEditor("one\ntwo", caret: 6)
        view.deleteCurrentLines(nil)
        #expect(view.string == "one")
    }

    @Test func deleteOnlyLine() {
        let view = makeEditor("solo", caret: 2)
        view.deleteCurrentLines(nil)
        #expect(view.string == "")
    }

    // MARK: - Move lines

    @Test func moveLineUp() {
        let view = makeEditor("one\ntwo\nthree\n", caret: 5)
        view.moveLinesUp(nil)
        #expect(view.string == "two\none\nthree\n")
        // Caret follows the moved line.
        #expect(view.selectedRange().location == 1)
    }

    @Test func moveFirstLineUpIsNoOp() {
        let view = makeEditor("one\ntwo\n", caret: 1)
        view.moveLinesUp(nil)
        #expect(view.string == "one\ntwo\n")
    }

    @Test func moveLineDown() {
        let view = makeEditor("one\ntwo\nthree\n", caret: 1)
        view.moveLinesDown(nil)
        #expect(view.string == "two\none\nthree\n")
    }

    @Test func moveLastLineDownIsNoOp() {
        let view = makeEditor("one\ntwo", caret: 6)
        view.moveLinesDown(nil)
        #expect(view.string == "one\ntwo")
    }

    @Test func moveLastLineWithoutNewlineUp() {
        let view = makeEditor("one\ntwo", caret: 5)
        view.moveLinesUp(nil)
        #expect(view.string == "two\none")
    }

    // MARK: - Indent / outdent

    @Test func indentAddsProfileUnit() {
        let view = makeEditor("alpha\nbeta\n", selection: NSRange(location: 0, length: 10), language: .swift)
        view.indentSelection(nil)
        #expect(view.string == "    alpha\n    beta\n")
    }

    @Test func indentUsesTwoSpacesForJavaScript() {
        let view = makeEditor("alpha\n", selection: NSRange(location: 0, length: 5), language: .javascript)
        view.indentSelection(nil)
        #expect(view.string == "  alpha\n")
    }

    @Test func outdentRemovesUpToTabWidth() {
        let view = makeEditor("    alpha\n  beta\nzero\n", selection: NSRange(location: 0, length: 21), language: .swift)
        view.outdentSelection(nil)
        #expect(view.string == "alpha\nbeta\nzero\n")
    }

    @Test func undoRestoresAfterLineCommand() {
        let view = makeEditor("one\ntwo\n", caret: 5)
        view.deleteCurrentLines(nil)
        #expect(view.string == "one\n")
        view.undoManager?.undo()
        #expect(view.string == "one\ntwo\n")
    }

    // MARK: - Comment toggling

    @Test func toggleSwiftLineComment() {
        let view = makeEditor("let a = 1\nlet b = 2\n", selection: NSRange(location: 0, length: 20), language: .swift)
        view.toggleComment(nil)
        #expect(view.string == "// let a = 1\n// let b = 2\n")
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        view.toggleComment(nil)
        #expect(view.string == "let a = 1\nlet b = 2\n")
    }

    @Test func togglePythonComment() {
        let view = makeEditor("x = 1\n", caret: 2, language: .python)
        view.toggleComment(nil)
        #expect(view.string == "# x = 1\n")
    }

    @Test func toggleCSSBlockComment() {
        let view = makeEditor("color: red;", selection: NSRange(location: 0, length: 11), language: .css)
        view.toggleComment(nil)
        #expect(view.string == "/* color: red; */")
        view.toggleComment(nil)
        #expect(view.string == "color: red;")
    }

    @Test func commentPreservesIndentation() {
        let view = makeEditor("    indented\n", caret: 6, language: .swift)
        view.toggleComment(nil)
        #expect(view.string == "    // indented\n")
    }

    // MARK: - Pairing

    @Test func openBracketAutoPairs() {
        let view = makeEditor("", caret: 0)
        view.insertText("(", replacementRange: view.selectedRange())
        #expect(view.string == "()")
        #expect(view.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func closingBracketSkipsOver() {
        let view = makeEditor("()", caret: 1)
        view.insertText(")", replacementRange: view.selectedRange())
        #expect(view.string == "()")
        #expect(view.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func bracketDoesNotPairBeforeText() {
        let view = makeEditor("word", caret: 0)
        view.insertText("(", replacementRange: view.selectedRange())
        #expect(view.string == "(word")
    }

    @Test func selectionGetsWrappedInPair() {
        let view = makeEditor("value", selection: NSRange(location: 0, length: 5))
        view.insertText("\"", replacementRange: view.selectedRange())
        #expect(view.string == "\"value\"")
        #expect(view.selectedRange() == NSRange(location: 1, length: 5))
    }

    @Test func apostropheInMarkdownDoesNotPair() {
        let view = makeEditor("it", caret: 2, language: .markdown)
        view.insertText("'", replacementRange: view.selectedRange())
        #expect(view.string == "it'")
    }

    @Test func deletingInsideEmptyPairRemovesBoth() {
        let view = makeEditor("()", caret: 1)
        view.deleteBackward(nil)
        #expect(view.string == "")
    }

    // MARK: - Tab

    @Test func tabInsertsSpacesPerProfile() {
        let view = makeEditor("x", caret: 0, language: .swift)
        view.insertTab(nil)
        #expect(view.string == "    x")
    }

    @Test func tabIndentsMultiLineSelection() {
        let view = makeEditor("a\nb\n", selection: NSRange(location: 0, length: 4), language: .javascript)
        view.insertTab(nil)
        #expect(view.string == "  a\n  b\n")
    }
}

@Suite("Markdown helpers")
struct MarkdownHelperTests {
    @Test func bulletContinues() {
        #expect(
            MarkdownListHelper.continuation(forLine: "- item") ==
            .continueWith("- ")
        )
        #expect(
            MarkdownListHelper.continuation(forLine: "  * item") ==
            .continueWith("  * ")
        )
    }

    @Test func orderedListIncrements() {
        #expect(
            MarkdownListHelper.continuation(forLine: "3. third") ==
            .continueWith("4. ")
        )
        #expect(
            MarkdownListHelper.continuation(forLine: "  1) first") ==
            .continueWith("  2) ")
        )
    }

    @Test func taskListContinuesUnchecked() {
        #expect(
            MarkdownListHelper.continuation(forLine: "- [x] done thing") ==
            .continueWith("- [ ] ")
        )
    }

    @Test func emptyItemTerminatesList() {
        let result = MarkdownListHelper.continuation(forLine: "- ")
        if case .terminate = result {
        } else {
            Issue.record("expected terminate, got \(String(describing: result))")
        }
    }

    @Test func nonListLineDoesNothing() {
        #expect(MarkdownListHelper.continuation(forLine: "plain text") == nil)
        #expect(MarkdownListHelper.continuation(forLine: "") == nil)
    }

    @Test func fenceDetection() {
        // Opening fence, no closer anywhere after → unclosed.
        #expect(MarkdownListHelper.lineOpensUnclosedFence("```swift", in: "```swift", lineStart: 0))
        // Opening fence with a closer below → balanced.
        let balanced = "```swift\nlet x = 1\n```"
        #expect(!MarkdownListHelper.lineOpensUnclosedFence("```swift", in: balanced, lineStart: 0))
        // Not a fence at all.
        #expect(!MarkdownListHelper.lineOpensUnclosedFence("plain", in: "plain", lineStart: 0))
    }
}

@Suite("Offline completion")
struct OfflineCompletionTests {
    @Test func keywordsMatchPrefix() {
        let results = OfflineCompletion.completions(
            forPrefix: "fun", language: .swift, documentText: ""
        )
        #expect(results.contains("func"))
    }

    @Test func documentWordsAreIncluded() {
        let results = OfflineCompletion.completions(
            forPrefix: "cal", language: .swift,
            documentText: "let calculateTotal = 1\nlet calendar = 2\n"
        )
        #expect(results.contains("calculateTotal"))
        #expect(results.contains("calendar"))
    }

    @Test func exactPrefixIsExcludedAndKeywordsComeFirst() {
        let results = OfflineCompletion.completions(
            forPrefix: "ret", language: .swift,
            documentText: "retryCount = 3"
        )
        // Keywords precede document words; keyword order is alphabetical.
        #expect(Array(results.prefix(2)) == ["rethrows", "return"])
        #expect(!results.contains("ret"))
        #expect(results.contains("retryCount"))
    }

    @Test func emptyPrefixYieldsNothing() {
        #expect(OfflineCompletion.completions(forPrefix: "", language: .swift, documentText: "words").isEmpty)
    }
}
