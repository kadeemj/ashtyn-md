# Task 29 — Search Snippets and Quick Open Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the FTS5 snippet-delimiter collision and render real highlights in the sidebar Search column, then add a fuzzy-title Quick Open (⇧⌘O) that jumps straight to a note — closing out Gate 5 Task 29.

**Architecture:** Two small, independently testable pure types (`SearchQuery`, `SearchSnippet`) replace inline logic in `LibraryStore.search()`. Quick Open is a new `QuickOpenModel`/`QuickOpenView` pair that mirrors `WikiLinkAutocompleteModel`'s proven debounce/cancellation shape and reuses its existing data sources (`LibraryStore.titleCandidates`, `LibraryStore.recents`, `FuzzyMatch`) — no new store methods. Presentation is a plain SwiftUI `.sheet` routed through the existing `LibraryCommandRequests` relay, attached to `LibraryWindowView` (the one view always mounted whenever a library is open).

**Tech Stack:** Swift 6, SwiftUI (macOS 14+), Swift Testing (`@Suite`/`@Test`/`#expect`), SQLite/FTS5 via the existing `LibraryStore` actor, XCTest for UI tests, XcodeGen.

**Design doc:** `docs/superpowers/specs/2026-08-02-task-29-search-quick-open-design.md`

## Global Constraints

These are standing project conventions (from `HANDOFF.md` / `docs/PHASE-7-HANDOFF.md`), not new to this task, but they apply to every step below:

- `project.yml` is the source of truth for the Xcode project; its `AshtynMD` target sources glob the whole `AshtynMD/` directory (excluding `Tests/**`/`UITests/**`), so new files under `AshtynMD/Features/Library/` and `AshtynMD/Tests/` are picked up automatically — but **run `xcodegen generate` after adding any file** and commit the regenerated `AshtynMD.xcodeproj`.
- Tests use Swift Testing (`@Suite`/`@Test`/`#expect`), hosted in the app target, not XCTest (XCTest is UI-tests-only).
- A Swift Testing test closure containing **only** `#expect` calls gives the compiler nothing to infer throwing-ness from; annotate closures explicitly as `async throws -> Void` when they call a `throws` API (see `withMigratedStore` usage in existing tests).
- `LibraryStore` instances must be `close()`d before removing their backing directory in a test — teardown races the WAL files otherwise.
- The test host is sandboxed: use `FileManager.default.temporaryDirectory`, never `/tmp`, for any on-disk test fixtures.
- Full verification for this plan: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests`, plus `./script/performance_gate.sh`.

---

### Task 1: `SearchQuery` — extract the FTS5 match-expression builder

**Files:**
- Create: `AshtynMD/Features/Library/SearchQuery.swift`
- Test: `AshtynMD/Tests/SearchQueryTests.swift`
- Modify: `AshtynMD/Core/Indexing/LibraryStore.swift:1003-1012` (the `search` method's query-construction lines only — leave the `snippet()` SQL call's delimiters untouched; Task 2 handles those)

**Interfaces:**
- Produces: `enum SearchQuery { static func ftsMatchExpression(for rawQuery: String) -> String? }`

- [ ] **Step 1: Write the failing tests**

Create `AshtynMD/Tests/SearchQueryTests.swift`:

```swift
import Testing

@testable import AshtynMD

@Suite("Search query FTS expression")
struct SearchQueryTests {
    @Test("returns nil for empty or whitespace-only input")
    func emptyInputReturnsNil() {
        #expect(SearchQuery.ftsMatchExpression(for: "") == nil)
        #expect(SearchQuery.ftsMatchExpression(for: "   ") == nil)
    }

    @Test("quotes a single term and appends a prefix wildcard")
    func singleTermIsQuotedWithWildcard() {
        #expect(SearchQuery.ftsMatchExpression(for: "alpha") == "\"alpha\"*")
    }

    @Test("quotes each whitespace-separated term independently")
    func multipleTermsAreQuotedSeparately() {
        #expect(SearchQuery.ftsMatchExpression(for: "alpha beta") == "\"alpha\" \"beta\"*")
    }

    @Test("escapes an embedded double quote so it cannot break out of the FTS term")
    func embeddedQuoteIsEscaped() {
        #expect(SearchQuery.ftsMatchExpression(for: #"a"b"#) == #""a""b"*"#)
    }

    @Test("a bare FTS boolean operator is quoted rather than interpreted")
    func ftsOperatorIsQuotedNotInterpreted() {
        #expect(
            SearchQuery.ftsMatchExpression(for: "alpha NOT beta")
                == "\"alpha\" \"NOT\" \"beta\"*"
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/SearchQueryTests`
Expected: FAIL — `SearchQuery` does not exist yet (build error).

- [ ] **Step 3: Implement `SearchQuery`**

Create `AshtynMD/Features/Library/SearchQuery.swift`:

```swift
import Foundation

/// Builds the FTS5 MATCH expression for a raw user search string: quotes
/// each whitespace-separated term (so FTS5 operators embedded in a query
/// can't be interpreted as syntax) and appends `*` to the final term for
/// search-as-you-type prefix matching.
enum SearchQuery {
    static func ftsMatchExpression(for rawQuery: String) -> String? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let terms = trimmed.split(separator: " ").map { term in
            "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        var expression = terms.joined(separator: " ")
        expression += "*"
        return expression
    }
}
```

- [ ] **Step 4: Update `LibraryStore.search()` to use it**

In `AshtynMD/Core/Indexing/LibraryStore.swift`, replace the current query-construction block (the trimming/splitting/quoting lines at the top of `search(_:limit:)`) with a call to `SearchQuery`. The method becomes:

```swift
    func search(_ rawQuery: String, limit: Int = 100) throws -> [SearchResult] {
        guard let ftsQuery = SearchQuery.ftsMatchExpression(for: rawQuery) else { return [] }

        // Column 3 is `content` in the v2 FTS shape (title, name,
        // relative_path, content), and the snippet lands immediately after the
        // record columns. Both indices are derived rather than written out:
        // hardcoding either still compiles and silently returns wrong strings.
        return try database.query("""
            SELECT \(Self.recordColumns(prefixedWith: "f")),
                   snippet(files_fts, 3, '⟦', '⟧', '…', 12)
            FROM files_fts
            JOIN files f ON f.id = files_fts.rowid
            WHERE files_fts MATCH ?
            ORDER BY bm25(files_fts, 10.0, 6.0, 3.0, 1.0)
            LIMIT ?
            """,
            [.text(ftsQuery), .integer(Int64(limit))]
        ) { row in
            SearchResult(
                record: Self.makeRecord(row),
                snippet: row.text(Self.recordColumnCount)
            )
        }
    }
```

(The `⟦`/`⟧` delimiters are untouched here on purpose — Task 2 changes them.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/SearchQueryTests`
Expected: PASS (all 5 tests).

- [ ] **Step 6: Run the existing search tests to confirm no regression**

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/LibraryStoreTests/searchFindsTitleAndContent -only-testing:AshtynMDTests/LibraryStoreSchemaV2Tests`
Expected: PASS — behavior is unchanged, only the construction moved.

- [ ] **Step 7: Commit**

```bash
git add AshtynMD/Features/Library/SearchQuery.swift AshtynMD/Tests/SearchQueryTests.swift AshtynMD/Core/Indexing/LibraryStore.swift AshtynMD.xcodeproj
git commit -m "refactor: extract SearchQuery as a testable FTS5 match-expression builder"
```

---

### Task 2: `SearchSnippet` — fix the delimiter collision and parse highlight segments

**Files:**
- Create: `AshtynMD/Features/Library/SearchSnippet.swift`
- Test: `AshtynMD/Tests/SearchSnippetTests.swift`
- Modify: `AshtynMD/Core/Indexing/LibraryStore.swift` (the `snippet()` SQL call's delimiter literals, inside `search(_:limit:)`, produced by Task 1)
- Modify: `AshtynMD/Tests/LibraryStoreSchemaV2Tests.swift` (add one integration test after `snippetColumnIndexIsDerived`, around line 212)

**Interfaces:**
- Consumes: nothing new
- Produces: `enum SearchSnippet { static let openMarker: Character; static let closeMarker: Character; struct Segment: Equatable { let text: String; let isHighlighted: Bool }; static func segments(from raw: String) -> [Segment] }`

- [ ] **Step 1: Write the failing tests**

Create `AshtynMD/Tests/SearchSnippetTests.swift`:

```swift
import Testing

@testable import AshtynMD

@Suite("Search snippet highlight parsing")
struct SearchSnippetTests {
    private let open = String(SearchSnippet.openMarker)
    private let close = String(SearchSnippet.closeMarker)

    @Test("an empty string produces no segments")
    func emptyStringProducesNoSegments() {
        #expect(SearchSnippet.segments(from: "") == [])
    }

    @Test("plain text with no markers is one unhighlighted segment")
    func noMarkersIsOnePlainSegment() {
        #expect(
            SearchSnippet.segments(from: "no markers here")
                == [.init(text: "no markers here", isHighlighted: false)]
        )
    }

    @Test("one highlighted span between plain runs")
    func oneHighlightedSpan() {
        let raw = "before \(open)middle\(close) after"
        #expect(
            SearchSnippet.segments(from: raw) == [
                .init(text: "before ", isHighlighted: false),
                .init(text: "middle", isHighlighted: true),
                .init(text: " after", isHighlighted: false),
            ]
        )
    }

    @Test("multiple highlighted spans")
    func multipleHighlightedSpans() {
        let raw = "\(open)one\(close) two \(open)three\(close)"
        #expect(
            SearchSnippet.segments(from: raw) == [
                .init(text: "one", isHighlighted: true),
                .init(text: " two ", isHighlighted: false),
                .init(text: "three", isHighlighted: true),
            ]
        )
    }

    @Test("the FTS5 ellipsis marker passes through as ordinary plain text")
    func ellipsisPassesThroughAsPlainText() {
        #expect(
            SearchSnippet.segments(from: "…\(open)hit\(close)…") == [
                .init(text: "…", isHighlighted: false),
                .init(text: "hit", isHighlighted: true),
                .init(text: "…", isHighlighted: false),
            ]
        )
    }

    @Test("an unterminated open marker degrades its remainder to plain text")
    func unterminatedOpenMarkerDegradesToPlain() {
        let raw = "before \(open)unterminated"
        #expect(
            SearchSnippet.segments(from: raw) == [
                .init(text: "before ", isHighlighted: false),
                .init(text: "unterminated", isHighlighted: false),
            ]
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/SearchSnippetTests`
Expected: FAIL — `SearchSnippet` does not exist yet (build error).

- [ ] **Step 3: Implement `SearchSnippet`**

Create `AshtynMD/Features/Library/SearchSnippet.swift`:

```swift
import Foundation

/// Highlight markers for FTS5 `snippet()` output, and the parser that turns
/// a delimited snippet string into renderable segments.
///
/// The markers are private-use-area scalars, not visible punctuation like
/// `⟦`/`⟧`: FTS5's `snippet()` does not escape its own markers, so a note
/// containing one of the marker characters in its own text would otherwise
/// corrupt the parse.
enum SearchSnippet {
    static let openMarker: Character = "\u{E000}"
    static let closeMarker: Character = "\u{E001}"

    struct Segment: Equatable {
        let text: String
        let isHighlighted: Bool
    }

    /// Splits a snippet string into plain/highlighted runs. Never throws:
    /// content that survives to end-of-string was never followed by a close
    /// marker. In well-formed FTS5 output that only happens for ordinary
    /// trailing plain text; if an open marker was itself never closed
    /// (malformed input), the same fallback keeps that remainder from being
    /// guessed at as highlighted.
    static func segments(from raw: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var isHighlighted = false

        for character in raw {
            switch character {
            case openMarker:
                if !current.isEmpty {
                    segments.append(Segment(text: current, isHighlighted: isHighlighted))
                    current = ""
                }
                isHighlighted = true
            case closeMarker:
                if !current.isEmpty {
                    segments.append(Segment(text: current, isHighlighted: isHighlighted))
                    current = ""
                }
                isHighlighted = false
            default:
                current.append(character)
            }
        }
        if !current.isEmpty {
            segments.append(Segment(text: current, isHighlighted: false))
        }
        return segments
    }
}
```

- [ ] **Step 4: Update the SQL `snippet()` call to use the new markers**

In `AshtynMD/Core/Indexing/LibraryStore.swift`, inside `search(_:limit:)` (the method Task 1 left with `snippet(files_fts, 3, '⟦', '⟧', '…', 12)`), change only the two delimiter literals:

```swift
        return try database.query("""
            SELECT \(Self.recordColumns(prefixedWith: "f")),
                   snippet(files_fts, 3, '\(SearchSnippet.openMarker)', '\(SearchSnippet.closeMarker)', '…', 12)
            FROM files_fts
            JOIN files f ON f.id = files_fts.rowid
            WHERE files_fts MATCH ?
            ORDER BY bm25(files_fts, 10.0, 6.0, 3.0, 1.0)
            LIMIT ?
            """,
            [.text(ftsQuery), .integer(Int64(limit))]
        ) { row in
            SearchResult(
                record: Self.makeRecord(row),
                snippet: row.text(Self.recordColumnCount)
            )
        }
```

- [ ] **Step 5: Add an integration test proving the real query produces the new markers**

In `AshtynMD/Tests/LibraryStoreSchemaV2Tests.swift`, add this test immediately after `snippetColumnIndexIsDerived` (after the closing brace at line 212):

```swift
    @Test("the snippet uses private-use-area markers, not visible bracket characters")
    func snippetUsesPrivateUseAreaMarkers() async throws {
        try await withMigratedStore(seed: false) { (store: LibraryStore) async throws -> Void in
            try await add(
                store, "Note.md",
                "Fruit Notes\n\nThe body mentions kumquats exactly once."
            )
            let results = try await store.search("kumquats")
            let snippet = results.first?.snippet ?? ""
            #expect(snippet.contains(SearchSnippet.openMarker))
            #expect(snippet.contains(SearchSnippet.closeMarker))
            #expect(!snippet.contains("⟦"))
            #expect(!snippet.contains("⟧"))
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/SearchSnippetTests -only-testing:AshtynMDTests/LibraryStoreSchemaV2Tests`
Expected: PASS (all `SearchSnippetTests` plus the new `snippetUsesPrivateUseAreaMarkers` test).

- [ ] **Step 7: Commit**

```bash
git add AshtynMD/Features/Library/SearchSnippet.swift AshtynMD/Tests/SearchSnippetTests.swift AshtynMD/Tests/LibraryStoreSchemaV2Tests.swift AshtynMD/Core/Indexing/LibraryStore.swift AshtynMD.xcodeproj
git commit -m "fix: use private-use-area FTS5 snippet delimiters instead of visible brackets"
```

---

### Task 3: Render highlighted snippets in `SearchColumnView`

**Files:**
- Modify: `AshtynMD/Features/Library/LibraryWindowView.swift:632` (the `Text(plainSnippet(...))` call), `:646` (the `.accessibilityValue(plainSnippet(...))` call), `:659-665` (the `plainSnippet` function itself)

**Interfaces:**
- Consumes: `SearchSnippet.segments(from raw: String) -> [SearchSnippet.Segment]` (Task 2)
- Produces: `SearchColumnView.highlightedSnippet(_:) -> Text`, `SearchColumnView.plainSnippetText(_:) -> String` (both private)

- [ ] **Step 1: Replace `plainSnippet` with two SearchSnippet-backed helpers**

In `AshtynMD/Features/Library/LibraryWindowView.swift`, replace the existing `plainSnippet` function (lines 659-665):

```swift
    /// Gate 5 renders these delimiters as real highlight; for now they are
    /// stripped so the snippet reads cleanly.
    private func plainSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "⟦", with: "")
            .replacingOccurrences(of: "⟧", with: "")
    }
```

with:

```swift
    private func highlightedSnippet(_ snippet: String) -> Text {
        SearchSnippet.segments(from: snippet).reduce(Text("")) { partial, segment in
            let piece = segment.isHighlighted
                ? Text(segment.text).fontWeight(.semibold).foregroundStyle(.primary)
                : Text(segment.text).foregroundStyle(.secondary)
            return partial + piece
        }
    }

    private func plainSnippetText(_ snippet: String) -> String {
        SearchSnippet.segments(from: snippet).map(\.text).joined()
    }
```

- [ ] **Step 2: Update the two call sites**

Line 632, inside the result row's `VStack`:

```swift
                    Text(result.record.title.isEmpty ? result.record.name : result.record.title)
                        .font(.body)
                        .lineLimit(1)
                    highlightedSnippet(result.snippet)
                        .font(.caption)
                        .lineLimit(2)
```

(Drop the row-level `.foregroundStyle(.secondary)` that used to sit on this `Text` — `highlightedSnippet` now applies `.foregroundStyle` per-segment.)

Line 646, the accessibility value:

```swift
                .accessibilityValue(plainSnippetText(result.snippet))
```

- [ ] **Step 3: Build and run the full unit suite**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug build`
Expected: builds cleanly.

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests`
Expected: PASS — this rendering change has no dedicated unit test (it's a thin `View` wrapper over the already-tested `SearchSnippet.segments`, matching how `WikiLinkAutocompletePopoverView`'s equivalent `highlightedTitle` rendering isn't unit tested either); correctness is covered transitively by `SearchSnippetTests` plus this full-suite build/test pass.

- [ ] **Step 4: Commit**

```bash
git add AshtynMD/Features/Library/LibraryWindowView.swift
git commit -m "feat: render FTS5 search snippet highlights instead of stripping them"
```

---

### Task 4: `QuickOpenModel` — fuzzy-title state machine

**Files:**
- Create: `AshtynMD/Features/Library/QuickOpen.swift` (model portion only — the View is added in Task 5)
- Test: `AshtynMD/Tests/QuickOpenModelTests.swift`

**Interfaces:**
- Consumes: `LibraryStore.recents(limit: Int = 30) throws -> [FileRecord]`, `LibraryStore.titleCandidates(limit: Int = 500) throws -> [FileRecord]`, `LibraryStore.primaryTag(forFileID: Int64) throws -> String?` (all existing), `FuzzyMatch.score(pattern: String, in candidate: String) -> FuzzyMatch.Score?` and `FuzzyMatch.Score.ranges: [NSRange]` (existing)
- Produces: `struct QuickOpenResult: Equatable, Identifiable { let record: FileRecord; let matchedRanges: [NSRange]; let primaryTag: String?; var id: Int64 { record.id } }`; `final class QuickOpenModel { init(store: LibraryStore?, debounce: Duration = .milliseconds(120), resultProvider: ResultProvider? = nil); var query: String; var results: [QuickOpenResult]; var selectedIndex: Int; var isLoading: Bool; func moveSelection(by offset: Int); func selectedRecord() -> FileRecord? }`

- [ ] **Step 1: Write the failing tests**

Create `AshtynMD/Tests/QuickOpenModelTests.swift`:

```swift
import Foundation
import Testing

@testable import AshtynMD

@Suite("Quick Open model", .serialized)
@MainActor
struct QuickOpenModelTests {
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

    private func result(_ title: String, id: Int64 = 1, ranges: [NSRange] = [], tag: String? = nil) -> QuickOpenResult {
        QuickOpenResult(record: record(title, id: id), matchedRanges: ranges, primaryTag: tag)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    @Test("shows recent notes immediately, before any query is typed")
    func showsRecentsOnInit() async {
        let recent = result("Recent Note")
        let model = QuickOpenModel(
            store: nil,
            debounce: .milliseconds(10),
            resultProvider: { query, _ in query.isEmpty ? [recent] : [] }
        )
        await settle()

        #expect(model.results.map(\.record.title) == ["Recent Note"])
    }

    @Test("debounces lookup and ranks the query")
    func debouncesAndRanksResults() async {
        let expected = result("Weekly Review")
        let model = QuickOpenModel(
            store: nil,
            debounce: .milliseconds(10),
            resultProvider: { query, _ in query.isEmpty ? [] : [expected] }
        )
        await settle()
        #expect(model.results.isEmpty)

        model.query = "week"
        await settle()

        #expect(model.results.map(\.record.title) == ["Weekly Review"])
        #expect(model.selectedRecord()?.title == "Weekly Review")
    }

    @Test("a newer query wins over a cancelled older lookup")
    func cancellationPreventsStaleResults() async {
        let old = result("Old Note")
        let new = result("New Note", id: 2)
        let model = QuickOpenModel(
            store: nil,
            debounce: .milliseconds(0),
            resultProvider: { query, _ in
                if query == "Old" {
                    try? await Task.sleep(for: .milliseconds(140))
                    return [old]
                }
                return query == "New" ? [new] : []
            }
        )
        await settle()

        model.query = "Old"
        try? await Task.sleep(for: .milliseconds(20))
        model.query = "New"
        await settle()

        #expect(model.results.map(\.record.title) == ["New Note"])
        try? await Task.sleep(for: .milliseconds(160))
        #expect(model.results.map(\.record.title) == ["New Note"])
    }

    @Test("selection navigation wraps around the result list")
    func keyboardNavigationWraps() async {
        let model = QuickOpenModel(
            store: nil,
            debounce: .milliseconds(0),
            resultProvider: { query, _ in
                query.isEmpty ? [self.result("One"), self.result("Two", id: 2)] : []
            }
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
        // Same rationale FuzzyMatch documents and WikiLinkAutocomplete
        // already relies on: a greedy scan would rank "Wireframes" above
        // "Work Retrospective" for "wr"; the DP matcher does not.
        let wireframes = record("Wireframes", id: 1)
        let workRetro = record("Work Retrospective", id: 2)
        let model = QuickOpenModel(
            store: nil,
            debounce: .milliseconds(0),
            resultProvider: { query, limit in
                guard !query.isEmpty else { return [] }
                return [wireframes, workRetro]
                    .compactMap { candidate -> (record: FileRecord, score: FuzzyMatch.Score)? in
                        FuzzyMatch.score(pattern: query, in: candidate.title).map { (candidate, $0) }
                    }
                    .sorted { $0.score.value > $1.score.value }
                    .prefix(limit)
                    .map { QuickOpenResult(record: $0.record, matchedRanges: $0.score.ranges, primaryTag: nil) }
            }
        )
        await settle()

        model.query = "wr"
        await settle()

        #expect(model.results.first?.record.title == "Work Retrospective")
        #expect(!(model.results.first?.matchedRanges.isEmpty ?? true))
    }

    @Test("the default provider ranks the whole title-candidate pool with FuzzyMatch")
    func defaultProviderUsesFuzzyMatchOverCandidatePool() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickOpenModelTests-\(UUID().uuidString)", isDirectory: true)
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

        let model = QuickOpenModel(store: store, debounce: .milliseconds(0))
        await settle()

        model.query = "wr"
        await settle()

        #expect(model.results.map(\.record.title) == ["Work Retrospective", "Wireframes"])

        try await store.close()
        try FileManager.default.removeItem(at: directory)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/QuickOpenModelTests`
Expected: FAIL — `QuickOpenModel`/`QuickOpenResult` do not exist yet (build error).

- [ ] **Step 3: Implement `QuickOpenResult` and `QuickOpenModel`**

Create `AshtynMD/Features/Library/QuickOpen.swift` with this content (the View from Task 5 is appended to this same file):

```swift
import AppKit
import Observation
import SwiftUI

/// One ranked candidate in the Quick Open list: the underlying note, the
/// character ranges `FuzzyMatch` matched (for bolding), and its primary tag
/// for the secondary metadata line — the same shape wiki-link autocomplete
/// already uses, so the app's two fuzzy-pickers stay visually consistent.
struct QuickOpenResult: Equatable, Identifiable {
    let record: FileRecord
    let matchedRanges: [NSRange]
    let primaryTag: String?
    var id: Int64 { record.id }
}

/// Main-actor state machine for Quick Open. The lookup is injected so
/// debounce/cancellation behavior stays unit-testable without opening a
/// SQLite-backed library, mirroring `WikiLinkAutocompleteModel`.
@MainActor
@Observable
final class QuickOpenModel {
    typealias ResultProvider = @MainActor (String, Int) async -> [QuickOpenResult]

    static let debounce: Duration = .milliseconds(120)
    static let resultLimit = 20
    /// How many recency-ordered title candidates the default provider
    /// fuzzy-ranks per lookup. `FuzzyMatch` is a DP matcher meant for "a few
    /// hundred short titles" (see its own doc comment), not a whole library.
    private static let candidatePoolSize = 500

    private let resultProvider: ResultProvider
    private let debounceDuration: Duration
    private var lookupTask: Task<Void, Never>?
    private var requestID = 0

    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            refresh()
        }
    }
    private(set) var results: [QuickOpenResult] = []
    private(set) var selectedIndex = 0
    private(set) var isLoading = false

    init(
        store: LibraryStore?,
        debounce: Duration = QuickOpenModel.debounce,
        resultProvider: ResultProvider? = nil
    ) {
        if let resultProvider {
            self.resultProvider = resultProvider
        } else {
            self.resultProvider = { query, limit in
                guard let store else { return [] }
                guard !query.isEmpty else {
                    let recents = (try? await store.recents(limit: limit)) ?? []
                    return await Self.makeResults(from: recents, store: store)
                }
                let candidates = (try? await store.titleCandidates(limit: Self.candidatePoolSize)) ?? []
                let ranked = candidates
                    .compactMap { record -> (record: FileRecord, score: FuzzyMatch.Score)? in
                        FuzzyMatch.score(pattern: query, in: record.title).map { (record, $0) }
                    }
                    .sorted { $0.score.value > $1.score.value }
                    .prefix(limit)
                let ranges = Dictionary(uniqueKeysWithValues: ranked.map { ($0.record.id, $0.score.ranges) })
                return await Self.makeResults(
                    from: ranked.map(\.record),
                    matchedRanges: ranges,
                    store: store
                )
            }
        }
        self.debounceDuration = debounce
        refresh()
    }

    private static func makeResults(
        from records: [FileRecord],
        matchedRanges: [Int64: [NSRange]] = [:],
        store: LibraryStore
    ) async -> [QuickOpenResult] {
        var results: [QuickOpenResult] = []
        results.reserveCapacity(records.count)
        for record in records {
            let tag = (try? await store.primaryTag(forFileID: record.id)) ?? nil
            results.append(
                QuickOpenResult(
                    record: record,
                    matchedRanges: matchedRanges[record.id] ?? [],
                    primaryTag: tag
                )
            )
        }
        return results
    }

    private func refresh() {
        requestID &+= 1
        let currentRequestID = requestID
        lookupTask?.cancel()
        results = []
        selectedIndex = 0
        isLoading = true

        let provider = resultProvider
        let currentQuery = query
        lookupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.debounceDuration ?? .zero)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let found = await provider(currentQuery, Self.resultLimit)
            guard !Task.isCancelled,
                  let self,
                  self.requestID == currentRequestID else {
                return
            }

            self.results = found
            self.selectedIndex = min(self.selectedIndex, max(0, found.count - 1))
            self.isLoading = false
            self.lookupTask = nil
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + offset).modulo(results.count)
    }

    func selectedRecord() -> FileRecord? {
        results[safe: selectedIndex]?.record
    }
}

@MainActor
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let result = self % divisor
        return result >= 0 ? result : result + divisor
    }
}
```

Note: the query test in `fuzzyRankingFavorsWordStartAlignment` and `debouncesAndRanksResults` set `model.query = "..."` directly; since `query`'s `didSet` calls `refresh()`, no separate trigger method is needed — this is the same reactive shape `SearchModel.query` already uses elsewhere in this codebase, just self-contained (no external `onQueryChange` indirection needed, because `QuickOpenModel` owns its data dependency via constructor injection like `WikiLinkAutocompleteModel` does).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests/QuickOpenModelTests`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add AshtynMD/Features/Library/QuickOpen.swift AshtynMD/Tests/QuickOpenModelTests.swift AshtynMD.xcodeproj
git commit -m "feat: add QuickOpenModel, a fuzzy-title jump state machine"
```

---

### Task 5: `QuickOpenView` — the SwiftUI list UI

**Files:**
- Modify: `AshtynMD/Features/Library/QuickOpen.swift` (append the View to the file created in Task 4)
- Modify: `AshtynMD/App/AccessibilityIdentifiers.swift` (add new identifiers)

**Interfaces:**
- Consumes: `QuickOpenModel` and `QuickOpenResult` (Task 4)
- Produces: `struct QuickOpenView: View { let model: QuickOpenModel; let onSelect: (FileRecord) -> Void }`; `AccessibilityID.quickOpen`, `AccessibilityID.quickOpenField`, `AccessibilityID.quickOpenResult(_ index: Int) -> String`

- [ ] **Step 1: Add the new accessibility identifiers**

In `AshtynMD/App/AccessibilityIdentifiers.swift`, add these lines inside `enum AccessibilityID` (after the existing `wikiLinkCreateNote` line):

```swift
    static let quickOpen = "library.quick-open"
    static let quickOpenField = "library.quick-open-field"
    static let quickOpenResultPrefix = "library.quick-open-result"

    static func quickOpenResult(_ index: Int) -> String {
        "\(quickOpenResultPrefix).\(index)"
    }
```

- [ ] **Step 2: Append `QuickOpenView` to `QuickOpen.swift`**

Add this to the end of `AshtynMD/Features/Library/QuickOpen.swift` (after the `Int.modulo` extension from Task 4):

```swift
/// SwiftUI content for the Quick Open sheet: a text field plus a ranked,
/// keyboard-navigable list of notes by fuzzy title match.
struct QuickOpenView: View {
    let model: QuickOpenModel
    let onSelect: (FileRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            TextField("Jump to a note…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($isFieldFocused)
                .onSubmit(selectCurrent)
                .accessibilityIdentifier(AccessibilityID.quickOpenField)
            Divider()
            if model.results.isEmpty && !model.isLoading {
                Text(model.query.isEmpty ? "No recent notes" : "No matching notes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            row(result, isSelected: index == model.selectedIndex, index: index)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 480)
        .onAppear { isFieldFocused = true }
        .onKeyPress(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.quickOpen)
    }

    private func selectCurrent() {
        guard let record = model.selectedRecord() else { return }
        onSelect(record)
        dismiss()
    }

    private func row(_ result: QuickOpenResult, isSelected: Bool, index: Int) -> some View {
        Button {
            onSelect(result.record)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedTitle(result)).lineLimit(1)
                Text(subtitle(for: result))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.quickOpenResult(index))
        .accessibilityLabel(displayTitle(result.record))
    }

    private func displayTitle(_ record: FileRecord) -> String {
        record.title.isEmpty ? record.name : record.title
    }

    private func subtitle(for result: QuickOpenResult) -> String {
        let tag = result.primaryTag.map { "#\($0)" } ?? "Untagged"
        let date = result.record.modifiedAt.formatted(.relative(presentation: .named))
        return "\(tag) · edited \(date)"
    }

    private func highlightedTitle(_ result: QuickOpenResult) -> AttributedString {
        let title = displayTitle(result.record)
        let attributed = NSMutableAttributedString(string: title)
        let fullLength = (title as NSString).length
        for range in result.matchedRanges {
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

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug build`
Expected: builds cleanly. (No dedicated unit test for this step — `QuickOpenView`'s rendering is exercised by the UI test in Task 7, matching how `WikiLinkAutocompletePopoverView` isn't unit tested either.)

- [ ] **Step 4: Commit**

```bash
git add AshtynMD/Features/Library/QuickOpen.swift AshtynMD/App/AccessibilityIdentifiers.swift AshtynMD.xcodeproj
git commit -m "feat: add QuickOpenView, the fuzzy jump-to-note list UI"
```

---

### Task 6: Wire ⇧⌘O end-to-end

**Files:**
- Modify: `AshtynMD/Features/Library/LibraryCommandRequests.swift` (add a `Request` case)
- Modify: `AshtynMD/App/AshtynMDApp.swift` (new menu command + UI-test keyboard-monitor fallback)
- Modify: `AshtynMD/Features/Library/LibraryWindowView.swift` (the root `LibraryWindowView`, lines 5-26 — add sheet state and presentation; **and** the existing `NoteListView.onReceive(LibraryCommandRequests.shared.requests)` switch, around line 382-386 — see Step 1a, required for the build to compile)

**Interfaces:**
- Consumes: `QuickOpenView`, `QuickOpenModel` (Task 4/5); existing `appModel.session.store: LibraryStore?`, `appModel.absoluteURL(of: FileRecord) -> URL?`, `appModel.openFile(at: URL)`
- Produces: `LibraryCommandRequests.Request.quickOpen`; the ⇧⌘O shortcut; `LibraryWindowView`'s Quick Open sheet

- [ ] **Step 1: Add the new request case**

In `AshtynMD/Features/Library/LibraryCommandRequests.swift`, change:

```swift
    enum Request: Sendable {
        case moveToFolder
    }
```

to:

```swift
    enum Request: Sendable {
        case moveToFolder
        case quickOpen
    }
```

- [ ] **Step 1a: Keep `NoteListView`'s existing switch exhaustive**

Adding `.quickOpen` above makes `NoteListView`'s existing `switch request { case .moveToFolder: ... }` (in `AshtynMD/Features/Library/LibraryWindowView.swift`, inside `NoteListView`'s `.onReceive(LibraryCommandRequests.shared.requests)`) non-exhaustive — Swift requires every enum case to be handled. This is a compile error, not a runtime behavior change, so it must be fixed in this same task, before Step 4 adds the new receiver. Change:

```swift
        .onReceive(LibraryCommandRequests.shared.requests) { request in
            switch request {
            case .moveToFolder: isMovePresented = true
            }
        }
```

to:

```swift
        .onReceive(LibraryCommandRequests.shared.requests) { request in
            switch request {
            case .moveToFolder: isMovePresented = true
            case .quickOpen: break // handled by LibraryWindowView's own receiver
            }
        }
```

- [ ] **Step 2: Add the menu command**

In `AshtynMD/App/AshtynMDApp.swift`, inside `CommandGroup(after: .textEditing)`, add a new button right after "Search Library" (before the `Divider()` that follows it):

```swift
                Button("Search Library") {
                    appModel.sidebarSelection = .search
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(appModel.libraryRoot == nil)

                Button("Quick Open…") {
                    LibraryCommandRequests.shared.send(.quickOpen)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(appModel.libraryRoot == nil)

                Divider()
```

- [ ] **Step 3: Add the UI-test keyboard-monitor fallback**

`UITestMenuTarget`'s local event monitor (in the same file) exists because synthetic XCTest key events don't always reliably trigger a SwiftUI `Commands` `.keyboardShortcut` — this is why "Search Library" already has a matching case there. Add the same for Quick Open.

First, add the action method to `UITestMenuTarget` (after the existing `search(_:)` method):

```swift
    @objc func search(_ sender: Any?) {
        appModel?.sidebarSelection = .search
    }

    @objc func quickOpen(_ sender: Any?) {
        LibraryCommandRequests.shared.send(.quickOpen)
    }
```

Then add a case to the keyDown switch in `installUITestKeyboardMonitor` (keyCode 31 is "O", the same virtual-keycode convention the existing `case (3, [.command, .shift])` for "F" already uses):

```swift
            case (3, [.command, .shift]):
                handled = { target.search(nil) }
            case (31, [.command, .shift]):
                handled = { target.quickOpen(nil) }
```

- [ ] **Step 4: Present the sheet from `LibraryWindowView`**

In `AshtynMD/Features/Library/LibraryWindowView.swift`, change the root `LibraryWindowView` struct from:

```swift
struct LibraryWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appModel.libraryRoot == nil {
                OnboardingView()
            } else {
                LibrarySplitView()
            }
        }
        .onReceive(StandaloneOpenRequests.shared.requests) { url in
            if appModel.contains(url) {
                appModel.sidebarSelection = .folder(url.deletingLastPathComponent())
                appModel.openFile(at: url)
            } else {
                openWindow(id: WindowID.standaloneDocument, value: url)
            }
        }
    }
}
```

to:

```swift
struct LibraryWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var isQuickOpenPresented = false

    var body: some View {
        Group {
            if appModel.libraryRoot == nil {
                OnboardingView()
            } else {
                LibrarySplitView()
            }
        }
        .onReceive(StandaloneOpenRequests.shared.requests) { url in
            if appModel.contains(url) {
                appModel.sidebarSelection = .folder(url.deletingLastPathComponent())
                appModel.openFile(at: url)
            } else {
                openWindow(id: WindowID.standaloneDocument, value: url)
            }
        }
        .onReceive(LibraryCommandRequests.shared.requests) { request in
            switch request {
            case .quickOpen: isQuickOpenPresented = true
            case .moveToFolder: break // handled by NoteListView's own receiver
            }
        }
        .sheet(isPresented: $isQuickOpenPresented) {
            QuickOpenView(
                model: QuickOpenModel(store: appModel.session.store),
                onSelect: { record in
                    if let url = appModel.absoluteURL(of: record) {
                        appModel.openFile(at: url)
                    }
                }
            )
        }
    }
}
```

(`NoteListView`'s existing `.onReceive(LibraryCommandRequests.shared.requests)` still handles `.moveToFolder` on its own — this new receiver on `LibraryWindowView` only needs to react to `.quickOpen`, with an explicit `case .moveToFolder: break` so the switch stays exhaustive.)

- [ ] **Step 5: Build**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug build`
Expected: builds cleanly.

- [ ] **Step 6: Commit**

```bash
git add AshtynMD/Features/Library/LibraryCommandRequests.swift AshtynMD/App/AshtynMDApp.swift AshtynMD/Features/Library/LibraryWindowView.swift AshtynMD.xcodeproj
git commit -m "feat: wire Quick Open to ⇧⌘O via LibraryCommandRequests"
```

---

### Task 7: UI test and full verification pass

**Files:**
- Modify: `AshtynMD/UITests/LibraryWorkflowUITests.swift` (add a new test)

**Interfaces:**
- Consumes: `AccessibilityID.quickOpenField`, `AccessibilityID.quickOpenResult(_:)` (Task 5); the ⇧⌘O shortcut (Task 6)

- [ ] **Step 1: Add the UI test**

In `AshtynMD/UITests/LibraryWorkflowUITests.swift`, add this test (following the style of the existing `testSearchFavoriteAndReopenRecentNote`):

```swift
    func testQuickOpenJumpsToNoteByFuzzyTitle() {
        launch()
        chooseSidebarItem("Notes")
        XCTAssertTrue(file(named: "Fixture Note").waitForExistence(timeout: 10))

        app.typeKey("o", modifierFlags: [.command, .shift])
        let field = element(AccessibilityID.quickOpenField)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("fixtnote")

        let result = element(AccessibilityID.quickOpenResult(0))
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()

        let editor = element(AccessibilityID.editor)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
    }
```

("fixtnote" is a valid fuzzy subsequence of "Fixture Note" — f-i-x-t-N-o-t-e — proving the fuzzy matcher, not just an exact prefix match, drives the result.)

- [ ] **Step 2: Attempt the UI test**

Run: `xcodegen generate && xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDUITests/LibraryWorkflowUITests/testQuickOpenJumpsToNoteByFuzzyTitle`

Expected: PASS. If it fails with `"Timed out while enabling automation mode"`, that is the pre-existing, environment-level TCC/automation-permission blocker documented in `docs/PHASE-7-HANDOFF.md` (Known problem #1) — not a defect in this change. Note the failure and its cause rather than treating it as a plan failure; the test source is still committed so it runs cleanly once that environment issue is resolved.

- [ ] **Step 3: Run the full unit suite**

Run: `xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests`
Expected: PASS — all suites, including the new `SearchQueryTests`, `SearchSnippetTests`, `QuickOpenModelTests`, and the extended `LibraryStoreSchemaV2Tests`.

- [ ] **Step 4: Run the performance gate**

Run: `./script/performance_gate.sh`
Expected: PASS — no change in this task touches the indexing/search hot path in a way that should regress the 10,000-file gate, but this confirms it.

- [ ] **Step 5: Commit**

```bash
git add AshtynMD/UITests/LibraryWorkflowUITests.swift
git commit -m "test: add Quick Open fuzzy-jump UI test"
```

---

## Post-plan follow-up (not part of this plan)

Update `docs/PHASE-7-HANDOFF.md` to mark Task 29 complete and Task 30 (export) as next, matching the pattern the Task 27/28 handoffs already established. This is a documentation update outside the scope of implementing Task 29 itself — do it as a final step once all seven tasks above are verified, not as part of any individual task's commit.
