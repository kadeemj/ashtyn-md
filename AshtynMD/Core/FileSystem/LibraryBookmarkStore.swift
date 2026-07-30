import Foundation

/// Persists security-scoped bookmarks for user-selected library roots so the
/// sandboxed app can reopen them across launches.
struct LibraryBookmarkStore {
    private static let defaultsKey = "libraryRootBookmarks.v1"

    struct ResolvedRoot {
        let url: URL
        /// True while the security scope is active; call `stopAccessing` when
        /// the library closes.
        let isAccessingSecurityScope: Bool

        func stopAccessing() {
            if isAccessingSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    static func saveRoot(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var all = storedBookmarks()
        all[AppSupportPaths.canonicalPath(of: url)] = bookmark
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    /// Resolves the most recently saved root, refreshing a stale bookmark.
    static func resolveKnownRoots() -> [ResolvedRoot] {
        storedBookmarks().values.compactMap { data in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { return nil }
            let accessing = url.startAccessingSecurityScopedResource()
            if stale { try? saveRoot(url) }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                return nil
            }
            return ResolvedRoot(url: url, isAccessingSecurityScope: accessing)
        }
    }

    static func forgetRoot(_ url: URL) {
        var all = storedBookmarks()
        all.removeValue(forKey: AppSupportPaths.canonicalPath(of: url))
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    private static func storedBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
