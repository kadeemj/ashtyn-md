import AppKit
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

    @Test("empty results offer a create-note action instead of a stale selection")
    func emptyResultsOfferCreateNote() async {
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(10),
            suggestionProvider: { _, _ in [] }
        )
        let text = "[[Missing Note"
        model.update(
            text: text,
            selection: NSRange(location: (text as NSString).length, length: 0),
            isMarkdown: true
        )
        await settle()

        #expect(model.isActive)
        #expect(!model.isLoading)
        #expect(model.suggestions.isEmpty)
        #expect(model.showsCreateNoteRow)
        let action = model.selectedAction()
        #expect(action?.insertion.range == NSRange(location: 2, length: 12))
        #expect(action?.insertion.replacement == "Missing Note")
        #expect(action?.noteToCreate == "Missing Note")
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
                // The sort is what makes this test mean anything: without it
                // `suggestions.first` would just be array-literal order
                // (Wireframes) no matter what the scores were, and the
                // assertion below would be checking nothing.
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

    @Test("an empty query after [[ shows recent notes instead of nothing")
    func emptyQueryShowsRecents() async {
        let recent = suggestion("Recent Note")
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(10),
            suggestionProvider: { query, _ in query.isEmpty ? [recent] : [] }
        )
        model.update(
            text: "[[",
            selection: NSRange(location: 2, length: 0),
            isMarkdown: true
        )
        await settle()

        #expect(model.isActive)
        #expect(model.suggestions.map(\.record.title) == ["Recent Note"])
        #expect(!model.showsCreateNoteRow)
    }

    @Test("selection navigation wraps through the create-note slot")
    func keyboardNavigationIncludesCreateNoteSlot() async {
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(0),
            suggestionProvider: { _, _ in [] }
        )
        model.update(
            text: "[[No Match Yet",
            selection: NSRange(location: 14, length: 0),
            isMarkdown: true
        )
        await settle()

        // Zero real suggestions, so the create-note row is the only slot;
        // wrapping by one in either direction lands back on it.
        #expect(model.selectedIndex == 0)
        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 0)
        #expect(model.selectedAction()?.noteToCreate == "No Match Yet")
    }
}

/// Controller-level behavior that needs a real NSTextView and a real store:
/// bracket completion against PlainTextView's auto-pairing, and the
/// duplicate-title guard on note creation.
@Suite("Wiki-link autocomplete controller", .serialized)
@MainActor
struct WikiLinkAutocompleteControllerTests {
    /// A notes folder plus a store indexing it, closed before the directory
    /// is removed so teardown doesn't race SQLite's WAL files.
    private func withLibrary(
        _ body: (LibraryStore, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WikiLinkAutocompleteControllerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let notes = directory.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let store = try LibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        do {
            try await body(store, notes)
            try await store.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func index(_ store: LibraryStore, _ path: String, _ text: String) async throws {
        var update = FileIndexUpdate(
            relativePath: path,
            size: Int64(text.utf8.count),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            languageID: .markdown,
            content: text
        )
        update.parsed = MarkdownMetadata.parse(text)
        _ = try await store.upsertFile(update)
    }

    private func makeEditor(_ text: String, caret: Int) -> PlainTextView {
        let view = PlainTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isRichText = false
        view.languageDefinition = LanguageDefinition.definition(for: .markdown)
        view.profile = EditorProfile.defaultProfile(for: .markdown)
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: folder.path)
            .sorted()
    }

    /// Waits for the debounced lookup rather than sleeping a fixed budget,
    /// so a slow machine doesn't turn into a flaky assertion.
    private func settle(_ model: WikiLinkAutocompleteModel) async {
        for _ in 0..<100 where model.isLoading {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("]] is appended only when auto-pairing didn't already add it")
    func closingBracketsAreAppendedOnlyWhenMissing() async throws {
        try await withLibrary { store, notes in
            try await index(store, "weekly-review.md", "Weekly Review\n\nbody")

            // "[[" typed immediately before existing text: PlainTextView
            // declines to auto-pair there, so nothing closes the link yet and
            // accepting has to supply the "]]" itself.
            let unpaired = makeEditor("tail text", caret: 0)
            let unpairedController = WikiLinkAutocompleteController(
                textView: unpaired,
                store: store,
                noteDirectory: { notes }
            )
            unpaired.insertText("[", replacementRange: unpaired.selectedRange())
            unpaired.insertText("[", replacementRange: unpaired.selectedRange())
            #expect(unpaired.string == "[[tail text")
            unpaired.insertText("wr", replacementRange: unpaired.selectedRange())
            #expect(unpaired.string == "[[wrtail text")

            unpairedController.update()
            await settle(unpairedController.model)
            #expect(unpairedController.model.suggestions.map(\.record.title) == ["Weekly Review"])
            #expect(unpairedController.acceptSelection())
            #expect(unpaired.string == "[[Weekly Review]]tail text")
            // Caret lands between the title and the closer either way.
            #expect(unpaired.selectedRange() == NSRange(location: 15, length: 0))

            // The already-covered branch, asserted alongside it so a
            // regression in either direction shows up here: typing "[[" at
            // the end of a line auto-pairs, and accepting must not double up.
            let paired = makeEditor("See ", caret: 4)
            let pairedController = WikiLinkAutocompleteController(
                textView: paired,
                store: store,
                noteDirectory: { notes }
            )
            paired.insertText("[", replacementRange: paired.selectedRange())
            paired.insertText("[", replacementRange: paired.selectedRange())
            #expect(paired.string == "See [[]]")
            paired.insertText("wr", replacementRange: paired.selectedRange())

            pairedController.update()
            await settle(pairedController.model)
            #expect(pairedController.acceptSelection())
            #expect(paired.string == "See [[Weekly Review]]")
        }
    }

    @Test("creating a note skips a title the library already has")
    func createNoteSkipsAnExistingTitle() async throws {
        try await withLibrary { store, notes in
            // Indexed *and* on disk: the note exists, it just wasn't in the
            // fuzzy-ranked candidate window (capped at 500 by recency), so
            // the popover offered to create it.
            try await index(store, "weekly-review.md", "Weekly Review\n\nbody")
            try Data("Weekly Review\n".utf8)
                .write(to: notes.appendingPathComponent("weekly-review.md"))

            var reindexCount = 0
            let controller = WikiLinkAutocompleteController(
                textView: makeEditor("", caret: 0),
                store: store,
                noteDirectory: { notes },
                reindex: { reindexCount += 1 }
            )

            // Folded title keys ignore case and whitespace runs, so this is
            // the same note.
            await controller.createNoteIfMissing(titled: "weekly   review")
            #expect(try names(in: notes) == ["weekly-review.md"])
            #expect(reindexCount == 0)

            // A genuinely new title still gets written.
            await controller.createNoteIfMissing(titled: "Grocery List")
            #expect(try names(in: notes) == ["Grocery List.md", "weekly-review.md"])
            #expect(reindexCount == 1)
        }
    }
}
