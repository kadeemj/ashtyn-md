import Foundation
import Observation

/// Library search: the query, its debounce, and the results.
@MainActor
@Observable
final class SearchModel {
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            onQueryChange?()
        }
    }

    private(set) var results: [SearchResult] = []

    /// Set by the composition root, which holds the session.
    var onQueryChange: (() -> Void)?

    private var task: Task<Void, Never>?

    /// Debounced so typing does not run an FTS query per keystroke.
    func refresh(using session: LibrarySession) {
        task?.cancel()
        guard let store = session.store else {
            results = []
            return
        }
        let query = self.query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }
        task = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = (try? await store.search(query)) ?? []
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
