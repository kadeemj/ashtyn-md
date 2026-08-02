# Wiki-Link Autocomplete Gap-Closing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four gaps identified between the design in `docs/superpowers/specs/2026-08-02-wiki-link-autocomplete-design.md` and the wiki-link autocomplete popover already shipped in commit `7a13e77` (`AshtynMD/Features/Editor/WikiLinkAutocomplete.swift`): fuzzy matching with highlighting, a "Create note" row, full AI ghost-text suppression, and metadata/recents polish.

**Architecture:** All work extends the existing `WikiLinkAutocompleteContext` / `WikiLinkAutocompleteModel` / `WikiLinkAutocompleteController` / `WikiLinkAutocompletePopoverView` stack in place — no new files. A new store-side candidate pool (`LibraryStore.titleCandidates`) replaces the SQL prefix filter so `FuzzyMatch` (already in the codebase, currently unused) can rank subsequence matches instead of only literal prefixes. The model's `suggestions` type grows from `[FileRecord]` to a new `WikiLinkSuggestion` struct carrying highlight ranges and a primary tag. A synthetic "create note" slot is appended to the selectable rows when a non-empty query has zero matches. AI ghost-text suppression is a one-line guard at the existing `isEligible` call site in `EditorTextView.Coordinator.textDidChange`.

**Tech Stack:** Swift 6, SwiftUI + AppKit (`NSPopover`/`NSHostingController`), SQLite via the existing `SQLiteDatabase`/`LibraryStore`, Swift Testing (`@Test`/`#expect`), XCTest UI tests.

## Global Constraints

- `xcodegen generate` must be re-run and `AshtynMD.xcodeproj` re-committed after any file is added (none are added by this plan — all changes are to existing files, so this is a non-issue here, but re-run it anyway before the final full-suite verification since Xcode's own project state can drift).
- All new/changed store queries go through `SQLiteDatabase.query`/`run` with positional `?` parameters — never interpolate untrusted values into SQL text.
- Stores must be `close()`d before their temp directory is removed in tests — use the existing `withStore` helper pattern, never a bare `defer`.
- `FuzzyMatch.score(pattern:in:)` is case-insensitive and already lowercases both sides; do not pre-fold input before calling it.
- A query must never be prefiltered in SQL by literal substring/prefix containment before fuzzy scoring — `FuzzyMatch` matches non-contiguous subsequences, so a substring `LIKE` prefilter would silently exclude valid matches (this is the exact "Wireframes"/"Work Retrospective" problem `FuzzyMatch` exists to fix).
- Every new/changed method in `WikiLinkAutocomplete.swift` stays `@MainActor`, matching the rest of the file.
- Run the full unit suite and the focused files touched by each task before committing that task; run the full unit suite once more at the very end.

---

### Task 1: Store-side candidate pool and per-file primary tag

**Files:**
- Modify: `AshtynMD/Core/Indexing/LibraryStore.swift:982` (insert after the existing `titleSuggestions` method)
- Test: `AshtynMD/Tests/TagHierarchyTests.swift` (append new `@Test` functions; reuses the file's existing `withStore`/`add` helpers)

**Interfaces:**
- Produces: `LibraryStore.titleCandidates(limit: Int = 500) throws -> [FileRecord]` — recency-ordered, unfiltered-by-query candidate pool for in-app fuzzy ranking. Consumed by Task 2.
- Produces: `LibraryStore.primaryTag(forFileID: Int64) throws -> String?` — the lexicographically-first direct tag for one file, or `nil`. Consumed by Task 2.

- [ ] **Step 1: Write the failing tests**

Append to `AshtynMD/Tests/TagHierarchyTests.swift`, directly after the existing `titleSuggestions()` test (after line 239):

```swift
    @Test("title candidates return every titled note regardless of query")
    func titleCandidatesReturnsAllTitledNotes() async throws {
        try await withStore { store in
            try await add(store, "a.md", "Weekly Review\n\nbody")
            try await add(store, "b.md", "Groceries\n\nbody")
            try await add(store, "untitled.md", "\n\nno first line")

            let candidates = try await store.titleCandidates(limit: 10)
            #expect(candidates.map(\.title).sorted() == ["Groceries", "Weekly Review"])
        }
    }

    @Test("title candidates respect the limit and recency order")
    func titleCandidatesRespectsLimitAndOrder() async throws {
        try await withStore { store in
            try await add(store, "old.md", "Old Note\n\nbody", modified: 1_700_000_000)
            try await add(store, "new.md", "New Note\n\nbody", modified: 1_700_000_100)

            let candidates = try await store.titleCandidates(limit: 1)
            #expect(candidates.map(\.title) == ["New Note"])
        }
    }

    @Test("primary tag is the lexicographically-first direct tag")
    func primaryTagIsLexicographicallyFirst() async throws {
        try await withStore { store in
            let fileID = try await add(store, "a.md", "Tagged\n\n#reading #work/alpha")
            let untaggedID = try await add(store, "b.md", "Untagged\n\nno tags")

            #expect(try await store.primaryTag(forFileID: fileID) == "reading")
            #expect(try await store.primaryTag(forFileID: untaggedID) == nil)
        }
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/TagHierarchyTests`
Expected: FAIL — `value of type 'LibraryStore' has no member 'titleCandidates'` / `'primaryTag'`.

- [ ] **Step 3: Implement the two store methods**

In `AshtynMD/Core/Indexing/LibraryStore.swift`, insert immediately after the closing brace of `titleSuggestions` (after line 982):

```swift

    /// A broad, recency-ordered candidate pool for in-app fuzzy ranking.
    /// Deliberately unfiltered by the query itself: `FuzzyMatch` matches
    /// non-contiguous subsequences, so filtering candidates by the raw
    /// query in SQL first would silently exclude valid matches (the exact
    /// "Wireframes" vs. "Work Retrospective" problem it exists to fix).
    func titleCandidates(limit: Int = 500) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE trashed_at IS NULL AND title != ''
            ORDER BY mtime DESC LIMIT ?
            """,
            [.integer(Int64(limit))],
            transform: Self.makeRecord
        )
    }

    /// The tag shown alongside a note title in the wiki-link popover: the
    /// lexicographically-first direct tag, or nil if the note has none.
    func primaryTag(forFileID fileID: Int64) throws -> String? {
        try database.query("""
            SELECT t.path FROM file_tags ft
            JOIN tags t ON t.id = ft.tag_id
            WHERE ft.file_id = ? AND ft.is_direct = 1
            ORDER BY t.path ASC LIMIT 1
            """,
            [.integer(fileID)],
            transform: { $0.text(0) }
        ).first
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/TagHierarchyTests`
Expected: PASS (all `TagHierarchyTests` tests, including the three new ones).

- [ ] **Step 5: Commit**

```bash
git add AshtynMD/Core/Indexing/LibraryStore.swift AshtynMD/Tests/TagHierarchyTests.swift
git commit -m "feat: add title candidate pool and primary tag lookup"
```

---

### Task 2: Fuzzy-ranked suggestions with highlighting

**Files:**
- Modify: `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift:62-118` (new `WikiLinkSuggestion` type, provider signature, default provider)
- Modify: `AshtynMD/Tests/WikiLinkAutocompleteTests.swift` (update existing tests' types; add fuzzy-ranking/highlighting tests)

**Interfaces:**
- Consumes: `LibraryStore.titleCandidates(limit:)`, `LibraryStore.primaryTag(forFileID:)` (Task 1). `FuzzyMatch.score(pattern:in:) -> FuzzyMatch.Score?` (existing, `Core/Notes/FuzzyMatch.swift`), where `Score` has `value: Double` and `ranges: [NSRange]`.
- Produces: `struct WikiLinkSuggestion: Equatable, Identifiable { let record: FileRecord; let matchedRanges: [NSRange]; let primaryTag: String?; var id: Int64 { record.id } }`. `WikiLinkAutocompleteModel.suggestions` becomes `[WikiLinkSuggestion]` (was `[FileRecord]`). `WikiLinkAutocompleteModel.SuggestionProvider` becomes `@MainActor (String, Int) async -> [WikiLinkSuggestion]`. Consumed by Task 3 (empty-query path), Task 4 (popover rendering).

- [ ] **Step 1: Write the failing tests**

In `AshtynMD/Tests/WikiLinkAutocompleteTests.swift`, replace the private `record(_:id:)` helper (lines 64-79) and the four `suggestionProvider` closures that return bare `[FileRecord]` so everything compiles against the new type, then add two new tests. Replace the whole `WikiLinkAutocompleteModelTests` struct body (lines 63-201) with:

```swift
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
                [wireframes, workRetro].compactMap { candidate in
                    FuzzyMatch.score(pattern: query, in: candidate.title).map {
                        WikiLinkSuggestion(record: candidate, matchedRanges: $0.ranges, primaryTag: nil)
                    }
                }
                .prefix(limit)
                .map { $0 }
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/WikiLinkAutocompleteModelTests`
Expected: FAIL to compile — `WikiLinkSuggestion` does not exist, `selectedAction()` does not exist, `suggestions` is `[FileRecord]` not convertible from `WikiLinkSuggestion`.

- [ ] **Step 3: Implement the ranking rewrite**

In `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift`, replace lines 62-118 (from `struct WikiLinkAutocompleteInsertion` through the end of `init`) with:

```swift
struct WikiLinkAutocompleteInsertion: Equatable {
    let range: NSRange
    let replacement: String

    var selectedRange: NSRange {
        NSRange(
            location: range.location + (replacement as NSString).length,
            length: 0
        )
    }
}

/// One ranked candidate in the popover: the underlying note, the character
/// ranges `FuzzyMatch` matched (for bolding), and its primary tag for the
/// secondary metadata line.
struct WikiLinkSuggestion: Equatable, Identifiable {
    let record: FileRecord
    let matchedRanges: [NSRange]
    let primaryTag: String?
    var id: Int64 { record.id }
}

/// What accepting the current selection does: always an insertion, plus a
/// note title to create on disk when the selection was the synthetic
/// "Create note" row.
struct WikiLinkAutocompleteAction: Equatable {
    let insertion: WikiLinkAutocompleteInsertion
    let noteToCreate: String?
}

/// Main-actor state machine for wiki-link suggestions. The lookup is injected
/// so trigger/range behavior and stale-result cancellation stay unit-testable
/// without opening a SQLite-backed library.
@MainActor
@Observable
final class WikiLinkAutocompleteModel {
    typealias SuggestionProvider = @MainActor (String, Int) async -> [WikiLinkSuggestion]

    static let debounce: Duration = .milliseconds(120)
    static let suggestionLimit = 20
    /// How many recency-ordered candidates the default provider fuzzy-ranks
    /// per lookup. `FuzzyMatch` is a DP matcher meant for "a few hundred
    /// short titles" (see its own doc comment), not a whole library.
    private static let candidatePoolSize = 500

    private let suggestionProvider: SuggestionProvider
    private let debounceDuration: Duration
    private let isAvailable: Bool
    private var lookupTask: Task<Void, Never>?
    private var requestID = 0

    private(set) var context: WikiLinkAutocompleteContext?
    private(set) var suggestions: [WikiLinkSuggestion] = []
    private(set) var selectedIndex = 0
    private(set) var isLoading = false
    var onChange: (() -> Void)?

    var isActive: Bool {
        guard let context else { return false }
        return !context.query.isEmpty
    }

    init(
        store: LibraryStore?,
        debounce: Duration = WikiLinkAutocompleteModel.debounce,
        suggestionProvider: SuggestionProvider? = nil
    ) {
        if let suggestionProvider {
            self.suggestionProvider = suggestionProvider
            isAvailable = true
        } else {
            self.suggestionProvider = { query, limit in
                guard let store else { return [] }
                guard !query.isEmpty else {
                    let recents = (try? await store.titleCandidates(limit: limit)) ?? []
                    return await Self.makeSuggestions(from: recents, store: store)
                }
                let candidates = (try? await store.titleCandidates(limit: Self.candidatePoolSize)) ?? []
                let ranked = candidates
                    .compactMap { record -> (record: FileRecord, score: FuzzyMatch.Score)? in
                        FuzzyMatch.score(pattern: query, in: record.title).map { (record, $0) }
                    }
                    .sorted { $0.score.value > $1.score.value }
                    .prefix(limit)
                let ranges = Dictionary(uniqueKeysWithValues: ranked.map { ($0.record.id, $0.score.ranges) })
                return await Self.makeSuggestions(
                    from: ranked.map(\.record),
                    matchedRanges: ranges,
                    store: store
                )
            }
            isAvailable = store != nil
        }
        self.debounceDuration = debounce
    }

    private static func makeSuggestions(
        from records: [FileRecord],
        matchedRanges: [Int64: [NSRange]] = [:],
        store: LibraryStore
    ) async -> [WikiLinkSuggestion] {
        var suggestions: [WikiLinkSuggestion] = []
        suggestions.reserveCapacity(records.count)
        for record in records {
            let tag = (try? await store.primaryTag(forFileID: record.id)) ?? nil
            suggestions.append(
                WikiLinkSuggestion(
                    record: record,
                    matchedRanges: matchedRanges[record.id] ?? [],
                    primaryTag: tag
                )
            )
        }
        return suggestions
    }
```

Leave `update`, `cancel`, `moveSelection`, and the old `selectedInsertion()` untouched for this step — Task 3 changes those. After this step the file will not compile yet (`update`'s `let records = await provider(...)` line still assigns into `self.suggestions` of the new type, which is fine since both are now `[WikiLinkSuggestion]`; but `selectedInsertion()` still references `record.title`/`record.name` on a `WikiLinkSuggestion`, which has no such members). Also update just `selectedInsertion()` (current lines 189-194) to unblock compilation, without yet touching its create-note behavior (that's Task 3):

```swift
    func selectedInsertion() -> WikiLinkAutocompleteInsertion? {
        guard let context, let suggestion = suggestions[safe: selectedIndex] else { return nil }
        let title = suggestion.record.title.isEmpty ? suggestion.record.name : suggestion.record.title
        guard !title.isEmpty else { return nil }
        return WikiLinkAutocompleteInsertion(range: context.targetRange, replacement: title)
    }
```

Also rename the call sites in `WikiLinkAutocompletePopoverView` and `WikiLinkAutocompleteController` from `model.selectedInsertion()` to keep compiling — no, leave the controller alone in this step; Task 3 renames `selectedInsertion()` to `selectedAction()` project-wide in one place, and Task 4 updates the view's use of `record` to `suggestion.record`. To keep this step's build green in isolation, also fix the one existing consumer that breaks immediately — `WikiLinkAutocompletePopoverView`'s `ForEach` (lines 232-257) still destructures `model.suggestions.enumerated()` as `(index, record)` and calls `record.title`/`record.relativePath`/`record.id` directly, which now fail since the element type is `WikiLinkSuggestion`. Change only the two now-invalid member accesses inside that closure, minimally, without touching layout yet:

```swift
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    let record = suggestion.record
                    Button {
```

(leave the rest of that closure's body exactly as-is for this step; Task 4 replaces the whole view body).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/WikiLinkAutocompleteModelTests -only-testing:AshtynMDTests/WikiLinkAutocompleteContextTests -only-testing:AshtynMDTests/TagHierarchyTests`
Expected: PASS — all `WikiLinkAutocompleteModelTests` (including the two new fuzzy-ranking tests), the unchanged `WikiLinkAutocompleteContextTests`, and `TagHierarchyTests` from Task 1.

- [ ] **Step 5: Commit**

```bash
git add AshtynMD/Features/Editor/WikiLinkAutocomplete.swift AshtynMD/Tests/WikiLinkAutocompleteTests.swift
git commit -m "feat: rank wiki-link suggestions with FuzzyMatch instead of a SQL prefix"
```

---

### Task 3: Empty-query recents and the "Create note" selectable slot

**Files:**
- Modify: `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift` (the `update`, `moveSelection`, `selectedInsertion` → `selectedAction` methods inside `WikiLinkAutocompleteModel`)
- Modify: `AshtynMD/Tests/WikiLinkAutocompleteTests.swift` (update one existing test's expectation; add new tests)

**Interfaces:**
- Consumes: `WikiLinkAutocompleteModel`/`WikiLinkSuggestion`/`WikiLinkAutocompleteAction` from Task 2.
- Produces: `WikiLinkAutocompleteModel.showsCreateNoteRow: Bool`. `WikiLinkAutocompleteModel.selectedAction() -> WikiLinkAutocompleteAction?` (replaces `selectedInsertion()`). Consumed by Task 4 (view) and Task 5 (controller/create-note action).

- [ ] **Step 1: Write the failing tests**

In `AshtynMD/Tests/WikiLinkAutocompleteTests.swift`:

First, update the existing `"empty results finish cleanly without a stale selection"` test — its final assertion changes, since a non-empty query with zero matches now offers a create-note action instead of `nil`:

```swift
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
```

Then append two new tests after the fuzzy-ranking tests added in Task 2:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/WikiLinkAutocompleteModelTests`
Expected: FAIL — `showsCreateNoteRow` and `selectedAction()` do not exist yet; the empty-query test currently cancels instead of activating.

- [ ] **Step 3: Implement recents-on-empty-query and the create-note slot**

In `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift`, first widen `isActive` itself — a freshly typed `[[` with nothing after it yet should count as active (so recents show, and so Task 6's AI-suppression engages immediately rather than only once a character is typed):

```swift
    var isActive: Bool {
        context != nil
    }
```

Then, in `WikiLinkAutocompleteModel.update` (current lines 120-131), remove the `!next.query.isEmpty` clause so an empty query still activates:

```swift
    func update(text: String, selection: NSRange, isMarkdown: Bool) {
        guard isAvailable,
              isMarkdown,
              selection.length == 0,
              let next = WikiLinkAutocompleteContext.detect(
                in: text,
                caretLocation: selection.location
              ) else {
            cancel()
            return
        }
```

Add a computed property right after `isActive`:

```swift
    /// True once a non-empty query has settled with zero matches — the
    /// popover then offers a synthetic "Create note" row as the only slot.
    var showsCreateNoteRow: Bool {
        guard let context else { return false }
        return !isLoading && !context.query.isEmpty && suggestions.isEmpty
    }

    private var slotCount: Int {
        suggestions.count + (showsCreateNoteRow ? 1 : 0)
    }
```

Replace `moveSelection` (current lines 182-187):

```swift
    func moveSelection(by offset: Int) {
        guard slotCount > 0 else { return }
        selectedIndex = (selectedIndex + offset).modulo(slotCount)
        onChange?()
    }
```

Replace `selectedInsertion()` (as it stands after Task 2's Step 3) with `selectedAction()`:

```swift
    func selectedAction() -> WikiLinkAutocompleteAction? {
        guard let context else { return nil }
        if let suggestion = suggestions[safe: selectedIndex] {
            let title = suggestion.record.title.isEmpty ? suggestion.record.name : suggestion.record.title
            guard !title.isEmpty else { return nil }
            return WikiLinkAutocompleteAction(
                insertion: WikiLinkAutocompleteInsertion(range: context.targetRange, replacement: title),
                noteToCreate: nil
            )
        }
        guard showsCreateNoteRow, selectedIndex == suggestions.count else { return nil }
        return WikiLinkAutocompleteAction(
            insertion: WikiLinkAutocompleteInsertion(range: context.targetRange, replacement: context.query),
            noteToCreate: context.query
        )
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/WikiLinkAutocompleteModelTests -only-testing:AshtynMDTests/WikiLinkAutocompleteContextTests`
Expected: PASS — all model tests including the rewritten empty-results test and the two new ones.

- [ ] **Step 5: Commit**

```bash
git add AshtynMD/Features/Editor/WikiLinkAutocomplete.swift AshtynMD/Tests/WikiLinkAutocompleteTests.swift
git commit -m "feat: show recent notes on an empty wiki-link query and offer create-note"
```

---

### Task 4: Popover view — highlighted matches, tag/date line, Create-note row

**Files:**
- Modify: `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift:211-265` (`WikiLinkAutocompletePopoverView`)
- Modify: `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift:367` (one line in `WikiLinkAutocompleteController.modelDidChange`, to give the taller view room)
- Modify: `AshtynMD/App/AccessibilityIdentifiers.swift` (add one identifier)

**Interfaces:**
- Consumes: `WikiLinkSuggestion.matchedRanges`/`primaryTag` (Task 2), `WikiLinkAutocompleteModel.showsCreateNoteRow` (Task 3).
- Produces: `AccessibilityID.wikiLinkCreateNote` — a fixed identifier for the create-note row, consumed by Task 5's UI test.

This task is view-only; there are no unit tests for SwiftUI view bodies anywhere else in this codebase (view correctness here is covered by the UI tests in Task 5), so there is no red/green cycle — write the implementation directly, then verify by building and by the UI test added in Task 5.

- [ ] **Step 1: Add the accessibility identifier**

In `AshtynMD/App/AccessibilityIdentifiers.swift`, immediately after the existing `wikiLinkSuggestion(_:)` function:

```swift
    static let wikiLinkCreateNote = "document.wiki-link-create-note"
```

- [ ] **Step 2: Rewrite the popover view**

In `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift`, replace the whole `WikiLinkAutocompletePopoverView` struct (current lines 211-265) with:

```swift
/// SwiftUI content hosted by the AppKit popover. The editor remains first
/// responder, so arrows/Return/Tab continue to be handled by PlainTextView.
@MainActor
private struct WikiLinkAutocompletePopoverView: View {
    let model: WikiLinkAutocompleteModel
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoading && model.suggestions.isEmpty {
                ProgressView("Searching notes…")
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            } else if model.suggestions.isEmpty && !model.showsCreateNoteRow {
                Text("No matching notes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            row(
                                title: highlightedTitle(suggestion),
                                subtitle: subtitle(for: suggestion),
                                isSelected: index == model.selectedIndex,
                                identifier: AccessibilityID.wikiLinkSuggestion(index),
                                label: suggestion.record.title.isEmpty
                                    ? suggestion.record.name : suggestion.record.title
                            )
                        }
                        if model.showsCreateNoteRow, let context = model.context {
                            row(
                                title: AttributedString("Create note \u{201C}\(context.query)\u{201D}"),
                                subtitle: nil,
                                isSelected: model.selectedIndex == model.suggestions.count,
                                identifier: AccessibilityID.wikiLinkCreateNote,
                                label: "Create note \(context.query)"
                            )
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(6)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.wikiLinkAutocomplete)
    }

    private func row(
        title: AttributedString,
        subtitle: String?,
        isSelected: Bool,
        identifier: String,
        label: String
    ) -> some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }

    private func subtitle(for suggestion: WikiLinkSuggestion) -> String {
        let tag = suggestion.primaryTag.map { "#\($0)" } ?? "Untagged"
        let date = suggestion.record.modifiedAt.formatted(.relative(presentation: .named))
        return "\(tag) · edited \(date)"
    }

    private func highlightedTitle(_ suggestion: WikiLinkSuggestion) -> AttributedString {
        let title = suggestion.record.title.isEmpty ? suggestion.record.name : suggestion.record.title
        let attributed = NSMutableAttributedString(string: title)
        let fullLength = (title as NSString).length
        for range in suggestion.matchedRanges {
            let bounded = NSRange(
                location: max(0, min(range.location, fullLength)),
                length: range.length
            )
            let clamped = NSRange(
                location: bounded.location,
                length: min(bounded.length, fullLength - bounded.location)
            )
            guard clamped.length > 0 else { continue }
            attributed.addAttribute(
                .font,
                value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                range: clamped
            )
        }
        return AttributedString(attributed)
    }
}
```

The `NSPopover`'s container size is what actually constrains the visible area in AppKit — the SwiftUI `ScrollView`'s `maxHeight` only bounds the content's own layout, not the window it's shown in. Left at its shipped `NSSize(width: 332, height: 120)`, the popover would clip the new (taller, two-line) rows to roughly two or three visible before scrolling, well short of the ~8-row design target. In `WikiLinkAutocompleteController.modelDidChange` (current line 367), widen it:

```swift
            popover.contentSize = NSSize(width: 332, height: 280)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add AshtynMD/Features/Editor/WikiLinkAutocomplete.swift AshtynMD/App/AccessibilityIdentifiers.swift
git commit -m "feat: highlight fuzzy matches and show tag/date metadata in the wiki-link popover"
```

---

### Task 5: Create-note action — plumbing, file creation, acceptance wiring

**Files:**
- Modify: `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift:267-381` (`WikiLinkAutocompleteController`)
- Modify: `AshtynMD/Features/Editor/EditorTextView.swift` (thread `reindex`/`reportError` alongside the existing `libraryStore`)
- Modify: `AshtynMD/Features/Editor/EditorContainerView.swift` (same threading)
- Modify: `AshtynMD/Features/Library/AppModel.swift:25` (add a public `reportError(_:)` forwarding method)
- Modify: `AshtynMD/Features/Library/LibraryWindowView.swift:694-698` (`DocumentAreaView`, supplies the two new closures)
- Test: `AshtynMD/UITests/EditorWorkflowUITests.swift` (new UI test)

**Interfaces:**
- Consumes: `WikiLinkAutocompleteModel.selectedAction()` (Task 3), `LibraryBrowser.availableURL(in:baseName:ext:)` (existing, `Features/Library/LibraryBrowser.swift:100`), `SaveCoordinator.writeAtomically(_:to:)` (existing, `Core/Documents/SaveCoordinator.swift:13`), `TitleFilename.sanitizedBaseName(_:)` (existing, sanitizes a title into a safe filename base).
- Produces: `WikiLinkAutocompleteController.init(textView:store:noteDirectory:reindex:reportError:)` — the three new parameters are all optional-defaulted so no other call site breaks.

- [ ] **Step 1: Write the failing UI test**

Append to `AshtynMD/UITests/EditorWorkflowUITests.swift`, directly after `testWikiLinkAutocompleteSelectsSuggestion` (after line 89):

```swift
    func testWikiLinkCreateNoteInsertsLinkAndCreatesFile() {
        launch()
        let editor = openFixtureNote()
        editor.click()
        editor.typeKey(.end, modifierFlags: [.command])
        editor.typeKey(.enter, modifierFlags: [])
        editor.typeKey(.enter, modifierFlags: [])
        editor.typeText("[[Brand New Note")

        let createRow = element(AccessibilityID.wikiLinkCreateNote)
        XCTAssertTrue(createRow.waitForExistence(timeout: 5), createRow.debugDescription)
        createRow.click()

        XCTAssertTrue(
            text(in: editor).contains("[[Brand New Note]]"),
            editor.debugDescription
        )

        chooseSidebarItem("Notes")
        XCTAssertTrue(file(named: "Brand New Note").waitForExistence(timeout: 10))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDUITests/EditorWorkflowUITests/testWikiLinkCreateNoteInsertsLinkAndCreatesFile`
Expected: FAIL — the create-note row never appears (the model already supports it as of Task 3/4, but nothing creates a file or reindexes yet, and more immediately, `AccessibilityID.wikiLinkCreateNote` render path exists but clicking it does nothing beyond insertion since the controller doesn't call `createNote` yet) — the test fails at the `file(named:)` assertion.

- [ ] **Step 3: Thread `reindex` and `reportError` through the editor view chain**

`AppModel.openError` (current line 25 of `AppModel.swift`) is `private(set)` — every existing `reportError` closure that touches it (e.g. line 92, `reportError: { [weak self] message in self?.openError = message }`) is defined *inside* `AppModel` itself, where the private setter is visible. `DocumentAreaView` lives in a different type, so it needs a proper entry point rather than reaching into the property directly.

In `AshtynMD/Features/Library/AppModel.swift`, add a small method immediately after the `openError` declaration (current line 25):

```swift
    func reportError(_ message: String) {
        openError = message
    }
```

In `AshtynMD/Features/Library/LibraryWindowView.swift`, update the `EditorContainerView` construction (current lines 694-698):

```swift
                EditorContainerView(
                    session: session,
                    previewContext: previewContext(for: session),
                    libraryStore: appModel.session.store,
                    reindex: { appModel.session.reindex() },
                    reportError: { appModel.reportError($0) }
                )
```

In `AshtynMD/Features/Editor/EditorContainerView.swift`, add two properties alongside `libraryStore` and pass them through to `EditorTextView`:

```swift
    var libraryStore: LibraryStore? = nil
    var reindex: (() -> Void)? = nil
    var reportError: ((String) -> Void)? = nil
```

and in the `EditorTextView(...)` construction inside `EditorContainerView`, add `reindex: reindex, reportError: reportError` alongside the existing `libraryStore: libraryStore`.

In `AshtynMD/Features/Editor/EditorTextView.swift`, add the same two properties to `EditorTextView` itself (alongside `var libraryStore: LibraryStore? = nil`):

```swift
    var reindex: (() -> Void)? = nil
    var reportError: ((String) -> Void)? = nil
```

Pass them into `makeCoordinator()`:

```swift
    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, libraryStore: libraryStore, reindex: reindex, reportError: reportError)
    }
```

In `Coordinator`, add matching stored properties and constructor parameters (alongside `private let libraryStore: LibraryStore?`):

```swift
        private let reindex: (() -> Void)?
        private let reportError: ((String) -> Void)?

        init(
            session: DocumentSession,
            libraryStore: LibraryStore? = nil,
            reindex: (() -> Void)? = nil,
            reportError: ((String) -> Void)? = nil
        ) {
            self.session = session
            self.libraryStore = libraryStore
            self.reindex = reindex
            self.reportError = reportError
```

(keep the rest of the existing `init` body, including the `#if DEBUG` block, unchanged — just extend the parameter list and the assignments above it).

In `configureWikiLinkAutocomplete(for:)`, pass a `noteDirectory` closure derived from `self.session` plus the two new closures into the controller:

```swift
        func configureWikiLinkAutocomplete(for textView: PlainTextView) {
            guard wikiLinkAutocomplete == nil else { return }
            let controller = WikiLinkAutocompleteController(
                textView: textView,
                store: libraryStore,
                noteDirectory: { [weak self] in self?.session.fileURL.deletingLastPathComponent() },
                reindex: reindex,
                reportError: reportError
            )
            wikiLinkAutocomplete = controller
            textView.wikiLinkAutocompleteKeyHandler = { [weak controller] event in
                controller?.handleKeyDown(event) == true
            }
            textView.wikiLinkAutocompleteAcceptHandler = { [weak controller] in
                controller?.acceptSelection() == true
            }
            textView.wikiLinkAutocompleteDismissHandler = { [weak controller] in
                controller?.dismiss() == true
            }
        }
```

- [ ] **Step 4: Implement `createNote` and route acceptance to it**

In `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift`, update `WikiLinkAutocompleteController` (current lines 267-381):

Change the stored properties and `init` (current lines 269-282):

```swift
final class WikiLinkAutocompleteController: NSObject, NSPopoverDelegate {
    let model: WikiLinkAutocompleteModel
    private weak var textView: PlainTextView?
    private var popover: NSPopover?
    private var isDismissing = false
    private let noteDirectory: () -> URL?
    private let reindex: (() -> Void)?
    private let reportError: ((String) -> Void)?

    init(
        textView: PlainTextView,
        store: LibraryStore?,
        noteDirectory: @escaping () -> URL? = { nil },
        reindex: (() -> Void)? = nil,
        reportError: ((String) -> Void)? = nil
    ) {
        model = WikiLinkAutocompleteModel(store: store)
        self.textView = textView
        self.noteDirectory = noteDirectory
        self.reindex = reindex
        self.reportError = reportError
        super.init()
        model.onChange = { [weak self] in
            self?.modelDidChange()
        }
    }
```

Replace `acceptSelection()` (current lines 318-331):

```swift
    func acceptSelection() -> Bool {
        guard let action = model.selectedAction(), let textView else { return false }
        dismiss()
        // Bracket auto-pairing (PlainTextView.insertText) already leaves a
        // closing "]]" after the caret in the common case of typing "[["
        // fresh — but not when "[[" was typed immediately before other
        // text, so auto-pairing didn't fire. Only append what's missing.
        let replacement = hasClosingBrackets(after: action.insertion.range, in: textView)
            ? action.insertion.replacement
            : action.insertion.replacement + "]]"
        guard textView.applyExternalEdit(
            range: action.insertion.range,
            replacement: replacement
        ) else {
            return false
        }
        // `selectedRange` is computed from the title-only replacement, so it
        // lands the caret right after the title regardless of whether "]]"
        // was already present or just appended above.
        textView.setSelectedRange(action.insertion.selectedRange)
        textView.scrollRangeToVisible(action.insertion.selectedRange)
        if let title = action.noteToCreate {
            createNote(titled: title)
        }
        return true
    }

    private func hasClosingBrackets(after range: NSRange, in textView: PlainTextView) -> Bool {
        let content = textView.string as NSString
        let closerRange = NSRange(location: NSMaxRange(range), length: 2)
        guard closerRange.location + closerRange.length <= content.length else { return false }
        return content.substring(with: closerRange) == "]]"
    }

    private func createNote(titled title: String) {
        guard let folder = noteDirectory(),
              let baseName = TitleFilename.sanitizedBaseName(title) else { return }
        let url = LibraryBrowser.availableURL(in: folder, baseName: baseName, ext: "md")
        do {
            try SaveCoordinator.writeAtomically(Data("\(title)\n".utf8), to: url)
            reindex?()
        } catch {
            reportError?("Couldn't create \u{201C}\(baseName).md\u{201D}: \(error.localizedDescription)")
        }
    }
```

The seeded body (`"\(title)\n"`) matters beyond convenience: note titles are derived from each file's first line, and wiki-link resolution matches on that derived title — an empty file would not resolve as the title just linked to.

- [ ] **Step 5: Run the UI test to verify it passes**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDUITests/EditorWorkflowUITests/testWikiLinkCreateNoteInsertsLinkAndCreatesFile`
Expected: PASS.

- [ ] **Step 6: Run the full unit suite to check nothing else broke**

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests`
Expected: PASS, same count as before plus the tests added in Tasks 1-3.

- [ ] **Step 7: Commit**

```bash
git add AshtynMD/Features/Editor/WikiLinkAutocomplete.swift AshtynMD/Features/Editor/EditorTextView.swift AshtynMD/Features/Editor/EditorContainerView.swift AshtynMD/Features/Library/AppModel.swift AshtynMD/Features/Library/LibraryWindowView.swift AshtynMD/UITests/EditorWorkflowUITests.swift
git commit -m "feat: create a note from the wiki-link popover when nothing matches"
```

---

### Task 6: Suppress the AI auto-trigger while the wiki-link popover is active

**Files:**
- Modify: `AshtynMD/Features/Editor/EditorTextView.swift:227-237` (`Coordinator.textDidChange`)
- Modify: `AshtynMD/App/UITestLaunchConfiguration.swift` (new launch flag)
- Modify: `AshtynMD/App/AshtynMDApp.swift:297-298` (consume the flag)
- Modify: `AshtynMD/UITests/UITestCase.swift:12-31` (`launch(...)` helper)
- Test: `AshtynMD/UITests/EditorWorkflowUITests.swift` (new UI test)

**Interfaces:**
- Consumes: `WikiLinkAutocompleteModel.isActive` (Task 2/3), `AISettings.shared` (existing, `Features/AICompletion/AISettings.swift`).
- Produces: `UITestLaunchConfiguration.enablesAutomaticAI: Bool`. `UITestCase.launch(reset:onboarding:standalone:automaticAI:)` gains one new defaulted parameter.

- [ ] **Step 1: Add the UI test launch flag**

In `AshtynMD/App/UITestLaunchConfiguration.swift`, add a field to the struct (after `opensStandalone`):

```swift
    let enablesAutomaticAI: Bool
```

and populate it in `current` (after `opensStandalone: arguments.contains("-ui-test-standalone")`):

```swift
            opensStandalone: arguments.contains("-ui-test-standalone"),
            enablesAutomaticAI: arguments.contains("-ui-test-automatic-ai")
```

- [ ] **Step 2: Consume the flag at launch**

`AppDelegate` is a plain `NSObject`/`NSApplicationDelegate`, not `@MainActor`-isolated itself — `applicationDidFinishLaunching`'s body is nonisolated code that hops onto the main actor via the existing `Task { @MainActor [weak self] in ... }`, which is exactly why that wrap is there. `AISettings` is `@MainActor`-isolated, so the new bootstrap must go *inside* that task, not in the synchronous `if` body around it (a same-file, non-isolated assignment to `AISettings.shared.automaticCompletionEnabled` would fail to compile).

In `AshtynMD/App/AshtynMDApp.swift`, inside the existing `if UITestLaunchConfiguration.current.isEnabled { ... }` block (starting at current line 297), add the two new lines at the very start of the existing `Task { @MainActor [weak self] in ... }` body (current line 299), before its first existing statement (the `for _ in 0..<60 { ... }` loop):

```swift
        if UITestLaunchConfiguration.current.isEnabled {
            Task { @MainActor [weak self] in
                // AISettings persists to the real UserDefaults.standard
                // across process launches, and -ui-test-reset only clears
                // the fixture library, not defaults — so this is set
                // unconditionally on every UI-test launch (not only inside
                // an `if enablesAutomaticAI` guard) to avoid one test run
                // leaking automatic completion into an unrelated later one.
                AISettings.shared.automaticCompletionEnabled = UITestLaunchConfiguration.current.enablesAutomaticAI
                if UITestLaunchConfiguration.current.enablesAutomaticAI {
                    AISettings.shared.selectedProvider = .ollama
                }
                // XCTest can launch the process without asking SwiftUI to
                // materialize its initial WindowGroup. Give the scene a few
                // turns first, then provide the same root view in a regular
                // AppKit window if it still has not appeared.
                for _ in 0..<60 {
```

(only the new lines from the comment through the `if UITestLaunchConfiguration.current.enablesAutomaticAI { ... }` block are additions; the rest shown here, including the second comment and the `for` loop, is existing code shown only for placement context and must not be duplicated).

- [ ] **Step 3: Add the launch helper parameter**

In `AshtynMD/UITests/UITestCase.swift`, update `launch` (current lines 12-31):

```swift
    func launch(
        reset: Bool = true,
        onboarding: Bool = false,
        standalone: Bool = false,
        automaticAI: Bool = false
    ) {
        app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-AppleKeyboardUIMode", "3",
            "-ApplePersistenceIgnoreState", "YES"
        ]
        if reset { app.launchArguments.append("-ui-test-reset") }
        if onboarding { app.launchArguments.append("-ui-test-show-onboarding") }
        if standalone { app.launchArguments.append("-ui-test-standalone") }
        if automaticAI { app.launchArguments.append("-ui-test-automatic-ai") }
        app.launch()
        app.activate()
    }
```

- [ ] **Step 4: Write the failing UI test**

Append to `AshtynMD/UITests/EditorWorkflowUITests.swift`, after `testWikiLinkCreateNoteInsertsLinkAndCreatesFile`:

```swift
    func testWikiLinkPopoverSuppressesAutomaticAIGhostText() {
        launch(automaticAI: true)
        let editor = openFixtureNote()
        editor.click()
        editor.typeKey(.end, modifierFlags: [.command])
        editor.typeKey(.enter, modifierFlags: [])
        editor.typeKey(.enter, modifierFlags: [])
        editor.typeText("[[Week")

        let suggestion = element(AccessibilityID.wikiLinkSuggestion(0))
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), suggestion.debugDescription)

        // The automatic trigger fires after 800ms of inactivity; give it a
        // full second while the popover is still open and confirm it never
        // arms.
        let ghostTextAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Document editor, AI suggestion: fixtureSuggestion"
            ),
            object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ghostTextAppeared], timeout: 1), .timedOut)

        // Dismissing the popover lets normal automatic AI ghost text resume.
        editor.typeKey(.escape, modifierFlags: [])
        waitForGhostText(in: editor)
    }
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDUITests/EditorWorkflowUITests/testWikiLinkPopoverSuppressesAutomaticAIGhostText`
Expected: FAIL at the final `waitForGhostText` (ghost text should already have appeared during the `wait(for:timeout: 1)` window instead of timing out, since nothing suppresses the automatic trigger yet) — i.e., the `XCTAssertEqual(..., .timedOut)` assertion fails because the wait actually `.completed`.

- [ ] **Step 6: Implement the suppression guard**

In `AshtynMD/Features/Editor/EditorTextView.swift`, in `Coordinator.textDidChange` (current lines 217-238), change the `isEligible` closure passed to `aiController.noteEdit`:

```swift
            wikiLinkAutocomplete?.update()
            // Any edit cancels a stale AI request; automatic completion
            // requires an empty selection, finished input composition, and
            // no active wiki-link popover (the two features must never
            // compete for the same keystroke).
            aiController.noteEdit(
                isEligible: { [weak textView, weak self] in
                    guard let textView else { return false }
                    guard self?.wikiLinkAutocomplete?.model.isActive != true else { return false }
                    return textView.selectedRange().length == 0 && !textView.hasMarkedText()
                },
                context: { [weak self] in
                    self?.makeAIRequest(trigger: .automatic)
                }
            )
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDUITests/EditorWorkflowUITests/testWikiLinkPopoverSuppressesAutomaticAIGhostText`
Expected: PASS.

- [ ] **Step 8: Run the full unit and UI suites**

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests`
Expected: PASS, matching the count from Task 5's Step 6.

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDUITests`
Expected: PASS, including both new wiki-link UI tests and the pre-existing 20. (This full UI run depends on the environment's XCUITest automation-permission state; if it fails with "Timed out while enabling automation mode," that is the pre-existing, documented environment blocker in `docs/PHASE-7-HANDOFF.md`, not a regression from this plan — re-run the two new tests individually to confirm they pass in isolation, as already verified in Steps 5 and 7 above.)

- [ ] **Step 9: Update the Phase 7 handoff**

In `docs/PHASE-7-HANDOFF.md`, update the Task 28 bullet to note the gap-closing follow-up is complete: fuzzy matching, the create-note row, tag/date metadata, recents-on-empty-query, and full AI-trigger suppression are now all in place, referencing this plan and the rescoped spec.

- [ ] **Step 10: Commit**

```bash
git add AshtynMD/Features/Editor/EditorTextView.swift AshtynMD/App/UITestLaunchConfiguration.swift AshtynMD/App/AshtynMDApp.swift AshtynMD/UITests/UITestCase.swift AshtynMD/UITests/EditorWorkflowUITests.swift docs/PHASE-7-HANDOFF.md
git commit -m "feat: suppress automatic AI ghost text while the wiki-link popover is open"
```
