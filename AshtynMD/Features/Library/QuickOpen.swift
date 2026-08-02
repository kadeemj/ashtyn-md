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
                    // `titleCandidates`, not `recents`: it filters out
                    // trashed/archived notes (`recents` does not, so a
                    // trashed note could otherwise be offered and then fail
                    // to open) and it still lists notes on a fresh library
                    // where nothing has ever been opened, matching
                    // `WikiLinkAutocompleteModel`'s empty-query behavior
                    // (`WikiLinkAutocomplete.swift`), which this was meant to
                    // mirror.
                    let candidates = (try? await store.titleCandidates(limit: limit)) ?? []
                    return await Self.makeResults(from: candidates, store: store)
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
            if model.isLoading && model.results.isEmpty {
                // Covers the ~120ms debounce window after each keystroke, so
                // the sheet doesn't visibly collapse to the empty state and
                // re-grow on every keystroke. Mirrors
                // `WikiLinkAutocompletePopoverView`'s equivalent branch.
                ProgressView("Searching notes…")
                    .controlSize(.small)
                    .padding(12)
            } else if model.results.isEmpty {
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
