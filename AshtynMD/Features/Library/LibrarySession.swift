import Foundation
import Observation

/// Owns the attached library: its root, the index store, the indexer, and the
/// on-disk folder tree.
///
/// Genuinely one per library rather than one per window, which is why it is
/// separated out — a second window should share the index, not fork it.
@MainActor
@Observable
final class LibrarySession {
    private(set) var root: LibraryBookmarkStore.ResolvedRoot?
    private(set) var store: LibraryStore?
    private(set) var indexer: LibraryIndexer?
    private(set) var folderTree: FolderNode?
    /// Non-nil while a scan is running, so the note list can say so instead of
    /// looking empty during the reindex the v2 migration forces.
    private(set) var indexingProgress: IndexingProgress?

    var isAttached: Bool { root != nil }

    var recoveryStore: RecoveryStore {
        if let url = root?.url { return .forLibrary(root: url) }
        return .standalone
    }

    // MARK: - Attach and detach

    /// Opens the index for `root` and returns the store, or throws.
    ///
    /// Indexing is deliberately *not* started here: the caller restores UI
    /// state first so a scan's change notifications cannot race the restore.
    func attach(_ root: LibraryBookmarkStore.ResolvedRoot) throws -> LibraryStore {
        self.root = root
        refreshFolderTree()
        let store = try LibraryStore.forLibrary(root: root.url)
        self.store = store
        self.indexer = LibraryIndexer(
            root: root.url,
            store: store,
            onChange: {
                Task { @MainActor in
                    AppModelChangeRelay.shared.libraryDidChange()
                }
            },
            onProgress: { progress in
                Task { @MainActor in
                    AppModelChangeRelay.shared.indexingProgressDidChange(progress)
                }
            }
        )
        return store
    }

    func startIndexing() async throws {
        try await indexer?.start()
    }

    func reindex() {
        Task { try? await indexer?.fullScan() }
    }

    /// Tears down the index and releases the security scope. Returns the work
    /// that has to finish asynchronously so the caller can order it.
    func detach() -> (indexer: LibraryIndexer?, store: LibraryStore?, root: LibraryBookmarkStore.ResolvedRoot?) {
        let previous = (indexer, store, root)
        indexer = nil
        store = nil
        self.root = nil
        folderTree = nil
        indexingProgress = nil
        return previous
    }

    func noteIndexingProgress(_ progress: IndexingProgress) {
        // Clear once the scan is complete so the header disappears.
        indexingProgress = progress.total == nil ? progress : nil
    }

    func refreshFolderTree() {
        guard let url = root?.url else {
            folderTree = nil
            return
        }
        Task {
            let tree = await Task.detached(priority: .userInitiated) {
                LibraryBrowser.folderTree(at: url)
            }.value
            self.folderTree = tree
        }
    }

    // MARK: - Paths

    func absoluteURL(of record: FileRecord) -> URL? {
        root?.url.appendingPathComponent(record.relativePath)
    }

    func absoluteURL(ofRelativePath path: String) -> URL? {
        root?.url.appendingPathComponent(path)
    }

    func relativePath(of url: URL) -> String? {
        guard let rootURL = root?.url else { return nil }
        let rootPath = AppSupportPaths.canonicalPath(of: rootURL)
        let path = AppSupportPaths.canonicalPath(of: url)
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// True when the given file lives inside the active library root.
    func contains(_ url: URL) -> Bool {
        guard let rootURL = root?.url else { return false }
        let rootPath = AppSupportPaths.canonicalPath(of: rootURL) + "/"
        return AppSupportPaths.canonicalPath(of: url).hasPrefix(rootPath)
    }
}
