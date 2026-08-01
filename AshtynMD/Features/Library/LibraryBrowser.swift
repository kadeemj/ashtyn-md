import Foundation

struct FolderNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    var children: [FolderNode]
    var id: String { url.path }
}

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let modifiedAt: Date
    let languageID: LanguageID
    var id: String { url.path }
}

/// Direct filesystem enumeration used by the Phase 1 UI. Phase 2 replaces the
/// read path with the SQLite/FTS5 index; the exclusion rules stay identical.
enum LibraryBrowser {
    static let excludedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "DerivedData",
        NoteLifecycle.trashDirectoryName, NoteLifecycle.archiveDirectoryName,
    ]

    static let maximumTreeDepth = 12

    static func isExcluded(_ url: URL, showHidden: Bool) -> Bool {
        let name = url.lastPathComponent
        if excludedDirectoryNames.contains(name) { return true }
        if !showHidden && name.hasPrefix(".") { return true }
        return false
    }

    /// Directory tree rooted at `root`, excluding VCS/build folders.
    static func folderTree(at root: URL, showHidden: Bool = false) -> FolderNode {
        FolderNode(
            url: root,
            name: root.lastPathComponent,
            children: childFolders(of: root, depth: 0, showHidden: showHidden)
        )
    }

    private static func childFolders(of url: URL, depth: Int, showHidden: Bool) -> [FolderNode] {
        guard depth < maximumTreeDepth else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return contents
            .filter { child in
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { return false }
                return !isExcluded(child, showHidden: showHidden)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { child in
                FolderNode(
                    url: child,
                    name: child.lastPathComponent,
                    children: childFolders(of: child, depth: depth + 1, showHidden: showHidden)
                )
            }
    }

    /// Supported text files directly inside `folder`, newest first.
    static func files(in folder: URL, showHidden: Bool = false) -> [FileItem] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )) ?? []
        return contents
            .compactMap { url -> FileItem? in
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .contentModificationDateKey]
                ), values.isDirectory != true else { return nil }
                guard !isExcluded(url, showHidden: showHidden) else { return nil }
                guard isSupportedTextFile(url) else { return nil }
                return FileItem(
                    url: url,
                    name: url.lastPathComponent,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    languageID: LanguageDetector.detectByExtension(fileName: url.lastPathComponent) ?? .plainText
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// A file is browsable when its extension belongs to a supported language,
    /// or when it has no extension (opened as plain text).
    static func isSupportedTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return true }
        return LanguageDetector.detectByExtension(fileName: url.lastPathComponent) != nil
    }

    /// Collision-safe URL for a new file: "Untitled.md", "Untitled 2.md", …
    static func availableURL(in folder: URL, baseName: String, ext: String) -> URL {
        let fileManager = FileManager.default
        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
