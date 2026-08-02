import Foundation
import Testing

@testable import AshtynMD

@Suite("Wiki-link autocomplete triggers")
struct WikiLinkAutocompleteContextTests {
    @Test("finds a target range that includes spaces")
    func targetRangeIncludesSpaces() {
        let text = "See [[Weekly Re"
        let context = WikiLinkAutocompleteContext.detect(
            in: text,
            caretLocation: (text as NSString).length
        )

        #expect(context?.openingRange == NSRange(location: 4, length: 2))
        #expect(context?.targetRange == NSRange(location: 6, length: 9))
        #expect(context?.rawQuery == "Weekly Re")
        #expect(context?.query == "Weekly Re")
    }

    @Test("does not trigger after a completed link or inside an alias")
    func completedLinkAndAliasAreInactive() {
        let complete = "See [[Weekly Review]]"
        #expect(
            WikiLinkAutocompleteContext.detect(
                in: complete,
                caretLocation: (complete as NSString).length
            ) == nil
        )

        let alias = "See [[Weekly Review|last week]]"
        #expect(
            WikiLinkAutocompleteContext.detect(
                in: alias,
                caretLocation: (alias as NSString).length
            ) == nil
        )
    }

    @Test("does not trigger across a newline or an escaped opening")
    func invalidContextsAreInactive() {
        let multiline = "[[Weekly\nReview"
        #expect(
            WikiLinkAutocompleteContext.detect(
                in: multiline,
                caretLocation: (multiline as NSString).length
            ) == nil
        )

        let escaped = #"\[[Weekly Re"#
        #expect(
            WikiLinkAutocompleteContext.detect(
                in: escaped,
                caretLocation: (escaped as NSString).length
            ) == nil
        )
    }
}

@Suite("Wiki-link autocomplete model", .serialized)
@MainActor
struct WikiLinkAutocompleteModelTests {
    private func record(_ title: String, id: Int64 = 1) -> FileRecord {
        FileRecord(
            id: id,
            relativePath: "\(title).md",
            name: "\(title).md",
            size: 0,
            modifiedAt: Date(timeIntervalSince1970: Double(id)),
            contentHash: nil,
            languageID: .markdown,
            resourceID: nil,
            isFavorite: false,
            lastOpenedAt: nil,
            title: title,
            titleKey: MarkdownMetadata.foldTitle(title)
        )
    }

    private func suggestion(_ title: String, id: Int64 = 1, ranges: [NSRange] = [], tag: String? = nil) -> WikiLinkSuggestion {
        WikiLinkSuggestion(record: record(title, id: id), matchedRanges: ranges, primaryTag: tag)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    @Test("debounces lookup and inserts the selected title")
    func insertionUsesTheTargetRange() async {
        let expected = suggestion("Weekly Review")
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(10),
            suggestionProvider: { _, _ in [expected] }
        )
        let text = "See [[Weekly Re]]"
        let caret = (text as NSString).range(of: "]]", options: [], range: NSRange(location: 0, length: (text as NSString).length)).location

        model.update(
            text: text,
            selection: NSRange(location: caret, length: 0),
            isMarkdown: true
        )
        await settle()

        #expect(model.suggestions.map(\.record.title) == ["Weekly Review"])
        let action = model.selectedAction()
        #expect(action?.insertion.range == NSRange(location: 6, length: 9))
        #expect(action?.insertion.replacement == "Weekly Review")
        #expect(action?.insertion.selectedRange == NSRange(location: 19, length: 0))
        #expect(action?.noteToCreate == nil)
    }

    @Test("standalone documents do not query without a library store")
    func unavailableWithoutStore() {
        let model = WikiLinkAutocompleteModel(store: nil, debounce: .milliseconds(0))
        model.update(
            text: "[[Library Note",
            selection: NSRange(location: 14, length: 0),
            isMarkdown: true
        )

        #expect(!model.isActive)
        #expect(model.suggestions.isEmpty)
        #expect(!model.isLoading)
    }

    @Test("a newer query wins over a cancelled older lookup")
    func cancellationPreventsStaleResults() async {
        let old = suggestion("Old Note")
        let new = suggestion("New Note", id: 2)
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(0),
            suggestionProvider: { prefix, _ in
                if prefix == "Old" {
                    try? await Task.sleep(for: .milliseconds(140))
                    return [old]
                }
                return [new]
            }
        )

        model.update(
            text: "[[Old",
            selection: NSRange(location: 5, length: 0),
            isMarkdown: true
        )
        try? await Task.sleep(for: .milliseconds(20))
        model.update(
            text: "[[New",
            selection: NSRange(location: 5, length: 0),
            isMarkdown: true
        )
        await settle()

        #expect(model.suggestions.map(\.record.title) == ["New Note"])
        try? await Task.sleep(for: .milliseconds(160))
        #expect(model.suggestions.map(\.record.title) == ["New Note"])
    }

    @Test("selection navigation wraps around the result list")
    func keyboardNavigation() async {
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(0),
            suggestionProvider: { _, _ in
                [self.suggestion("One"), self.suggestion("Two", id: 2)]
            }
        )
        model.update(
            text: "[[O",
            selection: NSRange(location: 3, length: 0),
            isMarkdown: true
        )
        await settle()

        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 1)
        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 0)
        model.moveSelection(by: -1)
        #expect(model.selectedIndex == 1)
    }

    @Test("fuzzy ranking favors a two-word-start alignment over a same-word run")
    func fuzzyRankingFavorsWordStartAlignment() async {
        // The Gate 0 rationale for using a DP instead of a greedy scan: a
        // greedy left-to-right scan matches "wr" against the r in "Work"
        // (no word-start bonus) and ranks "Work Retrospective" *below*
        // "Wireframes". The DP instead finds the alignment landing on the
        // R that starts "Retrospective" — two word-start hits outscore
        // "Wireframes"'s single word-start plus a same-word run. Verified
        // directly against FuzzyMatch: score("wr", "Work Retrospective") is
        // 16.8, score("wr", "Wireframes") is 11.0.
        let wireframes = record("Wireframes", id: 1)
        let workRetro = record("Work Retrospective", id: 2)
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(0),
            suggestionProvider: { query, limit in
                // NOTE (Task 2 deviation, flagged for review): the brief's
                // given closure computed a score per candidate but never
                // sorted by it, so `.first` was just array literal order
                // (Wireframes first) regardless of score — the test could
                // never have passed as written. Added the missing sort so
                // this actually exercises the word-start-alignment ranking
                // its own comment describes (confirmed against the existing,
                // correctly-sorted `FuzzyMatchTests.ranking()`).
                [wireframes, workRetro]
                    .compactMap { candidate -> (record: FileRecord, score: FuzzyMatch.Score)? in
                        FuzzyMatch.score(pattern: query, in: candidate.title).map { (candidate, $0) }
                    }
                    .sorted { $0.score.value > $1.score.value }
                    .prefix(limit)
                    .map { WikiLinkSuggestion(record: $0.record, matchedRanges: $0.score.ranges, primaryTag: nil) }
            }
        )
        model.update(
            text: "[[wr",
            selection: NSRange(location: 4, length: 0),
            isMarkdown: true
        )
        await settle()

        #expect(model.suggestions.first?.record.title == "Work Retrospective")
        #expect(!(model.suggestions.first?.matchedRanges.isEmpty ?? true))
    }

    @Test("the default provider ranks the whole candidate pool with FuzzyMatch, not a SQL prefix")
    func defaultProviderUsesFuzzyMatchOverCandidatePool() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WikiLinkAutocompleteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("library.sqlite"))

        var wireframes = FileIndexUpdate(
            relativePath: "wireframes.md",
            size: 10,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            languageID: .markdown,
            content: "Wireframes\n\nbody"
        )
        wireframes.parsed = MarkdownMetadata.parse("Wireframes\n\nbody")
        _ = try await store.upsertFile(wireframes)

        var workRetro = FileIndexUpdate(
            relativePath: "work-retro.md",
            size: 10,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            languageID: .markdown,
            content: "Work Retrospective\n\nbody"
        )
        workRetro.parsed = MarkdownMetadata.parse("Work Retrospective\n\nbody")
        _ = try await store.upsertFile(workRetro)

        let model = WikiLinkAutocompleteModel(store: store, debounce: .milliseconds(0))
        model.update(
            text: "[[wr",
            selection: NSRange(location: 4, length: 0),
            isMarkdown: true
        )
        await settle()

        // A prefix-only match (the old behavior) would return nothing at
        // all, since neither title starts with "wr". Fuzzy ranking not only
        // finds both but ranks "Work Retrospective" first (see the word-start
        // alignment rationale in the previous test).
        #expect(model.suggestions.map(\.record.title) == ["Work Retrospective", "Wireframes"])

        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }
}
