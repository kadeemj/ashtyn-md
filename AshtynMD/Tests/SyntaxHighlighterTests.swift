import Foundation
import Testing
@testable import AshtynMD

/// Per-language fixtures: every starter language must load its grammar and
/// produce sensible spans for a small idiomatic source sample.
@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    private func spans(for language: LanguageID, text: String) async -> [HighlightSpan] {
        let highlighter = SyntaxHighlighter()
        await highlighter.setLanguage(language)
        await highlighter.replaceText(text)
        return await highlighter.highlights(
            in: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    private func tokens(
        _ spans: [HighlightSpan], at substring: String, in text: String
    ) -> Set<SyntaxToken> {
        let range = (text as NSString).range(of: substring)
        guard range.location != NSNotFound else { return [] }
        return Set(spans.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.token))
    }

    @Test func everyLanguageWithAGrammarLoadsIt() {
        let expected: [LanguageID] = [
            .swift, .python, .javascript, .typescript, .json,
            .yaml, .html, .css, .shell, .markdown,
        ]
        for id in expected {
            #expect(GrammarRegistry.configuration(for: id) != nil, "\(id.rawValue)")
            #expect(
                GrammarRegistry.configuration(for: id)?.queries[.highlights] != nil,
                "\(id.rawValue) highlights query"
            )
        }
        #expect(GrammarRegistry.configuration(for: .plainText) == nil)
    }

    @Test func swiftFixture() async {
        let source = """
        // A comment
        func greet(name: String) -> String {
            let count = 42
            return "Hello, \\(name)"
        }
        """
        let result = await spans(for: .swift, text: source)
        #expect(tokens(result, at: "func", in: source).contains(.keyword))
        #expect(tokens(result, at: "// A comment", in: source).contains(.comment))
        #expect(tokens(result, at: "42", in: source).contains(.number))
        #expect(!result.isEmpty)
    }

    @Test func pythonFixture() async {
        let source = """
        # comment
        def add(a, b):
            return a + b or "text"
        """
        let result = await spans(for: .python, text: source)
        #expect(tokens(result, at: "def", in: source).contains(.keyword))
        #expect(tokens(result, at: "# comment", in: source).contains(.comment))
        #expect(tokens(result, at: "\"text\"", in: source).contains(.string))
    }

    @Test func javascriptFixture() async {
        let source = """
        // note
        const value = 7;
        function run() { return "done"; }
        """
        let result = await spans(for: .javascript, text: source)
        #expect(tokens(result, at: "const", in: source).contains(.keyword))
        #expect(tokens(result, at: "\"done\"", in: source).contains(.string))
        #expect(tokens(result, at: "7", in: source).contains(.number))
    }

    @Test func typescriptFixture() async {
        let source = """
        interface Point { x: number }
        const p: Point = { x: 1 };
        """
        let result = await spans(for: .typescript, text: source)
        #expect(tokens(result, at: "interface", in: source).contains(.keyword))
        #expect(!result.isEmpty)
    }

    @Test func jsonFixture() async {
        let source = "{\"key\": [1, 2, true]}"
        let result = await spans(for: .json, text: source)
        #expect(tokens(result, at: "\"key\"", in: source).isEmpty == false)
        #expect(tokens(result, at: "1", in: source).contains(.number))
    }

    @Test func yamlFixture() async {
        let source = """
        name: test
        items:
          - one
          - 22
        """
        let result = await spans(for: .yaml, text: source)
        #expect(!result.isEmpty)
    }

    @Test func htmlFixture() async {
        let source = "<html><body class=\"main\"><h1>Title</h1></body></html>"
        let result = await spans(for: .html, text: source)
        #expect(!result.isEmpty)
    }

    @Test func cssFixture() async {
        let source = ".main { color: #fff; margin: 4px; }"
        let result = await spans(for: .css, text: source)
        #expect(!result.isEmpty)
    }

    @Test func shellFixture() async {
        let source = """
        #!/bin/bash
        # comment
        echo "hello $USER"
        """
        let result = await spans(for: .shell, text: source)
        #expect(tokens(result, at: "# comment", in: source).contains(.comment))
        #expect(!result.isEmpty)
    }

    @Test func markdownFixture() async {
        let source = """
        # Heading

        Some text with a [link](https://example.com).

        ```swift
        let x = 1
        ```
        """
        let result = await spans(for: .markdown, text: source)
        #expect(!result.isEmpty)
    }

    @Test func plainTextProducesNoSpans() async {
        let result = await spans(for: .plainText, text: "just words here")
        #expect(result.isEmpty)
    }

    @Test func incrementalEditKeepsHighlightsCorrect() async {
        let highlighter = SyntaxHighlighter()
        await highlighter.setLanguage(.swift)
        let v1 = "let x = 1\n"
        await highlighter.replaceText(v1)

        // Append a function; edited range covers the insertion.
        let v2 = "let x = 1\nfunc go() {}\n"
        let insertLocation = (v1 as NSString).length
        let insertLength = ("func go() {}\n" as NSString).length
        await highlighter.applyEdit(
            newText: v2,
            editedRange: NSRange(location: insertLocation, length: insertLength),
            delta: insertLength,
            sequence: 1
        )
        let result = await highlighter.highlights(
            in: NSRange(location: 0, length: (v2 as NSString).length)
        )
        let funcRange = (v2 as NSString).range(of: "func")
        #expect(result.contains { NSIntersectionRange($0.range, funcRange).length > 0 && $0.token == .keyword })
    }

    @Test func editWithUnicodeAndEmojiKeepsRangesAligned() async {
        let highlighter = SyntaxHighlighter()
        await highlighter.setLanguage(.swift)
        // Emoji are 2 UTF-16 units; ranges are UTF-16 throughout.
        let v1 = "let s = \"🙂🙂\"\nlet n = 5\n"
        await highlighter.replaceText(v1)
        let all = await highlighter.highlights(
            in: NSRange(location: 0, length: (v1 as NSString).length)
        )
        let numberRange = (v1 as NSString).range(of: "5")
        #expect(all.contains { NSIntersectionRange($0.range, numberRange).length > 0 && $0.token == .number })
        let stringRange = (v1 as NSString).range(of: "\"🙂🙂\"")
        #expect(all.contains { NSIntersectionRange($0.range, stringRange).length > 0 && $0.token == .string })
    }

    @Test func staleEditSequencesAreDropped() async {
        let highlighter = SyntaxHighlighter()
        await highlighter.setLanguage(.swift)
        await highlighter.replaceText("let a = 1\n")

        let newer = "let a = 12\n"
        await highlighter.applyEdit(
            newText: newer,
            editedRange: NSRange(location: 9, length: 1),
            delta: 1,
            sequence: 2
        )
        // A late-arriving older edit must not clobber newer text.
        await highlighter.applyEdit(
            newText: "let a = 1x\n",
            editedRange: NSRange(location: 9, length: 1),
            delta: 1,
            sequence: 1
        )
        let spans = await highlighter.highlights(
            in: NSRange(location: 0, length: (newer as NSString).length)
        )
        let numberRange = (newer as NSString).range(of: "12")
        #expect(spans.contains { NSIntersectionRange($0.range, numberRange).length > 0 && $0.token == .number })
    }
}
