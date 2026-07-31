import Foundation
import Observation

/// The sidebar's tag tree and the counts on the fixed rows.
@MainActor
@Observable
final class TagsModel {
    private(set) var tree: [TagNode] = []
    private(set) var counts = LibraryCounts()
    /// Inbox count, which is a folder query rather than a flag.
    private(set) var inboxCount = 0

    /// Refreshed only when the indexer commits a batch — never from a view
    /// body, where it would run on every layout pass.
    func refresh(using session: LibrarySession) {
        guard let store = session.store else {
            tree = []
            counts = LibraryCounts()
            inboxCount = 0
            return
        }
        Task {
            tree = (try? await store.tagTree()) ?? []
            counts = (try? await store.counts()) ?? LibraryCounts()
            inboxCount = (try? await store.files(inFolder: InboxFolder.name).count) ?? 0
        }
    }

    func setPinned(_ pinned: Bool, key: String, using session: LibrarySession) {
        guard let store = session.store else { return }
        Task {
            try? await store.setTagPinned(pinned, key: key)
            refresh(using: session)
        }
    }

    /// Count for a fixed sidebar row, or nil when the row shows no badge.
    func count(for item: SidebarItem) -> Int? {
        switch item {
        case .inbox: return inboxCount
        case .notes: return counts.notes
        case .untagged: return counts.untagged
        case .todo: return counts.todo
        case .pinned: return counts.pinned
        case .favorites: return counts.favorites
        case .archive: return counts.archived
        case .trash: return counts.trashed
        case .tag(let key): return node(forKey: key)?.count
        default: return nil
        }
    }

    /// Test seam: lets tree-walking be checked without a live store.
    func setTreeForTesting(_ nodes: [TagNode]) {
        tree = nodes
    }

    func node(forKey key: String) -> TagNode? {
        func search(_ nodes: [TagNode]) -> TagNode? {
            for node in nodes {
                if node.key == key { return node }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return search(tree)
    }
}
