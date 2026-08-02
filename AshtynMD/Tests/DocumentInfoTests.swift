import Testing

@testable import AshtynMD

@Suite("Document info")
struct DocumentInfoTests {
    @Test("Markdown statistics use the current buffer")
    func markdownStatisticsUseCurrentBuffer() {
        let text = """
        Weekly Review

        Wrapping up the week #work/alpha and #reading

        - [ ] draft the summary
        - [x] collect metrics

        See also [[Fixture Note]] for context.
        """

        let stats = DocumentInfoStats(text: text, languageID: .markdown)

        #expect(stats.title == "Weekly Review")
        #expect(stats.titleKey == "weekly review")
        #expect(stats.characterCount == text.count)
        #expect(stats.wordCount > 0)
        #expect(stats.readingTimeMinutes == 1)
        #expect(stats.todoTotal == 2)
        #expect(stats.todoOpen == 1)
        #expect(stats.tags == ["work/alpha", "reading"])
        #expect(stats.outgoingLinks.map(\.target) == ["Fixture Note"])
        #expect(stats.outgoingLinks.map(\.key) == ["fixture note"])
    }

    @Test("plain text statistics avoid Markdown metadata parsing")
    func plainTextStatistics() {
        let text = "# not a title\n\nwords here"
        let stats = DocumentInfoStats(text: text, languageID: .plainText)

        #expect(stats.title.isEmpty)
        #expect(stats.titleKey.isEmpty)
        #expect(stats.wordCount == 6)
        #expect(stats.characterCount == text.count)
        #expect(stats.todoTotal == 0)
        #expect(stats.todoOpen == 0)
        #expect(stats.tags.isEmpty)
        #expect(stats.outgoingLinks.isEmpty)
    }
}
