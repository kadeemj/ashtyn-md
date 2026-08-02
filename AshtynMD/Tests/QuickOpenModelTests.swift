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
