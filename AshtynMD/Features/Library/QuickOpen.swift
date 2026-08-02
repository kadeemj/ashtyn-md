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
