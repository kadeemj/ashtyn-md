import Foundation

/// How far a scan has got, for the note list's progress header.
struct IndexingProgress: Sendable, Equatable {
    var scanned: Int
    /// nil while the total is still unknown — enumeration is lazy on purpose.
    var total: Int?
}

/// Enumerates a library root, keeps the LibraryStore in sync with disk, and
/// reacts to FSEvents. Designed for libraries up to ~10,000 supported files:
/// enumeration is lazy, work happens in batches off the main actor.
actor LibraryIndexer {
    /// Files above this size keep metadata rows but skip full-text content.
    static let contentIndexingSizeLimit: Int64 = 2 * 1024 * 1024
    private static let scanBatchSize = 200

    private let root: URL
    private let rootPath: String
    private let store: LibraryStore
    private var watcher: FSEventsWatcher?
    private var eventTask: Task<Void, Never>?
    private var showHiddenFiles: Bool

    /// Called after any batch of index changes lands; the UI refreshes from it.
    private let onChange: @Sendable () -> Void
    /// Fired once per scan batch. The v2 migration forces a full reindex, and
    /// this is what lets the note list say so instead of looking broken.
    private let onProgress: (@Sendable (IndexingProgress) -> Void)?

    init(
        root: URL,
        store: LibraryStore,
        showHiddenFiles: Bool = false,
        onChange: @escaping @Sendable () -> Void,
        onProgress: (@Sendable (IndexingProgress) -> Void)? = nil
    ) {
        self.root = root
        self.rootPath = AppSupportPaths.canonicalPath(of: root)
        self.store = store
        self.showHiddenFiles = showHiddenFiles
        self.onChange = onChange
        self.onProgress = onProgress
    }

    func setShowHiddenFiles(_ show: Bool) async throws {
        guard show != showHiddenFiles else { return }
        showHiddenFiles = show
        try await fullScan()
    }

    // MARK: - Lifecycle

    func start() async throws {
        let watcher = FSEventsWatcher(root: root)
        self.watcher = watcher
        watcher.start()
        eventTask = Task { [weak self] in
            for await paths in watcher.events {
                guard let self else { break }
                await self.handleEventPaths(paths)
            }
        }
        try await fullScan()
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Scanning

    /// Walks the whole library lazily and reconciles the store with disk:
    /// new/changed files are (re)indexed, vanished files are pruned.
    func fullScan() async throws {
        let fileManager = FileManager.default
        var seenPaths = Set<String>()
        var batch: [URL] = []

        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if LibraryBrowser.excludedDirectoryNames.contains(item.lastPathComponent) ||
                    (!showHiddenFiles && item.lastPathComponent.hasPrefix(".")) {
                    (enumerator as? FileManager.DirectoryEnumerator)?.skipDescendants()
                }
                continue
            }
            guard !LibraryBrowser.isExcluded(item, showHidden: showHiddenFiles),
                  LibraryBrowser.isSupportedTextFile(item),
                  let relative = relativePath(of: item) else { continue }
            seenPaths.insert(relative)
            batch.append(item)
            if batch.count >= Self.scanBatchSize {
                try await indexBatch(batch)
                batch.removeAll(keepingCapacity: true)
                onProgress?(IndexingProgress(scanned: seenPaths.count, total: nil))
                await Task.yield()
            }
        }
        try await indexBatch(batch)
        let lifecyclePaths = try await indexLifecycleFiles()
        seenPaths.formUnion(lifecyclePaths)
        try await store.removeFilesNotIn(seenPaths)
        // Once per scan, never per file: a note losing its last tag should not
        // make every other note pay for a prune.
        _ = try await store.pruneOrphanTags()
        onProgress?(IndexingProgress(scanned: seenPaths.count, total: seenPaths.count))
        onChange()
    }

    /// Indexes the two hidden, app-owned recovery trees separately from the
    /// user-visible library. Their rows retain the real on-disk path so they
    /// can still be opened, while the store mirrors their lifecycle state.
    private func indexLifecycleFiles() async throws -> Set<String> {
        var seen = Set<String>()

        let archiveRoot = root.appendingPathComponent(
            NoteLifecycle.archiveDirectoryName, isDirectory: true
        )
        if FileManager.default.fileExists(atPath: archiveRoot.path) {
            let enumerator = FileManager.default.enumerator(
                at: archiveRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )
            while let item = enumerator?.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true { continue }
                guard item.lastPathComponent != NoteLifecycle.trashMetadataName,
                      LibraryBrowser.isSupportedTextFile(item),
                      let relative = relativePath(of: item) else { continue }
                seen.insert(relative)
                try await indexFileIfNeeded(at: item, lifecycle: .archived)
            }
        }

        let trashRoot = root.appendingPathComponent(
            NoteLifecycle.trashDirectoryName, isDirectory: true
        )
        if FileManager.default.fileExists(atPath: trashRoot.path) {
            let enumerator = FileManager.default.enumerator(
                at: trashRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )
            while let item = enumerator?.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true || item.lastPathComponent == NoteLifecycle.trashMetadataName {
                    continue
                }
                guard LibraryBrowser.isSupportedTextFile(item),
                      let relative = relativePath(of: item),
                      let metadata = try? NoteLifecycle.metadata(for: item) else { continue }
                seen.insert(relative)
                try await indexFileIfNeeded(at: item, lifecycle: .trashed(metadata))
            }
        }

        return seen
    }

    private func indexBatch(_ urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        for url in urls {
            try await indexFileIfNeeded(at: url)
        }
    }

    /// Indexes one file when its size/mtime differ from the stored row, or
    /// when the row is missing. Recognizes moves via the resource identifier.
    private enum LifecycleLocation: Sendable, Equatable {
        case active
        case archived
        case trashed(NoteLifecycle.TrashMetadata)
    }

    private func indexFileIfNeeded(
        at url: URL,
        lifecycle: LifecycleLocation = .active
    ) async throws {
        guard let relative = relativePath(of: url),
              let disk = SaveCoordinator.diskState(of: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        if let existing = try await store.record(forRelativePath: relative) {
            let sameStamp = abs(existing.modifiedAt.timeIntervalSince1970 - disk.modificationDate.timeIntervalSince1970) < 0.001
            // reindexPending overrides the stamp check: after the v2 migration
            // size and mtime match but the derived columns are all empty.
            if sameStamp && existing.size == size && !existing.reindexPending,
               lifecycleMatches(existing, lifecycle) { return }
        } else if let moved = try await store.record(forResourceID: disk.resourceID) {
            // Same inode, new path: it moved. Keep identity, then fall through
            // to refresh metadata (content may also have changed).
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(moved.relativePath).path) {
                try await store.updatePath(ofFileWithResourceID: disk.resourceID, to: relative)
            }
        }

        let (content, hash) = readIndexableContent(of: url, size: size)
        let language = LanguageDetector.detect(
            fileName: url.lastPathComponent, contents: content
        )

        var update = FileIndexUpdate(
            relativePath: relative,
            size: size,
            modifiedAt: disk.modificationDate,
            // Free: attributesOfItem was already read above.
            createdAt: attributes[.creationDate] as? Date,
            contentHash: hash,
            languageID: language,
            resourceID: disk.resourceID,
            content: content
        )
        // Only Markdown is parsed. `#` is the comment character in shell,
        // Python, YAML, and Ruby, so every shebang and `# TODO` in the library
        // would otherwise become a sidebar tag — and a Swift file's first line
        // makes a catastrophic auto-filename.
        if language == .markdown, let content {
            update.parsed = MarkdownMetadata.parse(content)
        }
        try await store.upsertFile(update)
        switch lifecycle {
        case .active:
            try await store.markRestored(relativePath: relative)
        case .archived:
            try await store.markArchived(relativePath: relative)
        case .trashed(let metadata):
            try await store.markTrashed(relativePath: relative, metadata: metadata)
        }
    }

    private func lifecycleMatches(_ record: FileRecord, _ lifecycle: LifecycleLocation) -> Bool {
        switch lifecycle {
        case .active:
            return !record.isArchived && record.trashedAt == nil
        case .archived:
            return record.isArchived && record.trashedAt == nil
        case .trashed(let metadata):
            return record.trashedOriginPath == metadata.originalRelativePath &&
                record.trashedAt.map {
                    abs($0.timeIntervalSince1970 - metadata.trashedAt.timeIntervalSince1970) < 0.001
                } == true
        }
    }

    /// Repoints a row after the app itself renames a file.
    ///
    /// Called by the title-rename coordinator *before* FSEvents reports the
    /// move. The later event batch then finds a row whose mtime and size match
    /// and returns early, while the old path matches nothing — so this is fully
    /// idempotent with no suppression set and no timers to leak.
    func applyRename(from oldRelativePath: String, to newRelativePath: String) async throws {
        let url = root.appendingPathComponent(newRelativePath)
        guard let disk = SaveCoordinator.diskState(of: url) else { return }
        try await store.updatePath(
            ofFileWithResourceID: disk.resourceID, to: newRelativePath
        )
        _ = oldRelativePath
    }

    /// Reads content for FTS when the file is small enough and not binary.
    private func readIndexableContent(of url: URL, size: Int64) -> (String?, String?) {
        guard size <= Self.contentIndexingSizeLimit,
              let data = try? Data(contentsOf: url) else { return (nil, nil) }
        // Binary sniff: a NUL byte near the start means "not text".
        if data.prefix(8192).contains(0) { return (nil, nil) }
        let (text, _) = TextFileEncoding.decode(data)
        return (text, SaveCoordinator.contentHash(of: LineEnding.normalizeToLF(text)))
    }

    // MARK: - FSEvents

    /// Test seam: FSEvents cannot be driven deterministically from a unit test.
    func handleEventPathsForTesting(_ paths: [String]) async {
        await handleEventPaths(paths)
    }

    private func handleEventPaths(_ paths: [String]) async {
        var changed = false

        // The normal enumerator deliberately skips these directories. A
        // lifecycle mutation can therefore only be reconciled by the dedicated
        // pass, which also reads Trash manifests.
        if paths.contains(where: { path in
            guard let relative = relativePath(of: URL(fileURLWithPath: path)) else { return false }
            return NoteLifecycle.isLifecyclePath(relative)
        }) {
            try? await fullScan()
            return
        }

        // Paths that still exist are processed before paths that are gone.
        //
        // FSEvents reports a batch in arbitrary order. Handling the vanished
        // old path of a rename first used to delete the row outright, so the
        // subsequent index of the new path found no resource_id match and
        // inserted a fresh row — losing the id, the favorite flag, recents,
        // and the saved view state. Existing-first means the move is detected
        // by inode and identity is preserved, which also fixes plain Finder
        // renames. This becomes constant, not rare, once filenames follow
        // note titles.
        let ordered = paths.sorted { left, right in
            let leftExists = FileManager.default.fileExists(atPath: left)
            let rightExists = FileManager.default.fileExists(atPath: right)
            if leftExists != rightExists { return leftExists }
            return false
        }

        for path in ordered {
            let url = URL(fileURLWithPath: path)
            guard let relative = relativePath(of: url) else { continue }
            if relativePathIsExcluded(relative) { continue }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            do {
                if !exists {
                    // Removed, or renamed away: prune this path (and subtree —
                    // we can't know whether it was a folder). A rename's new
                    // path was already handled above, which repointed the row,
                    // so this now matches nothing rather than deleting it.
                    try await store.removeFile(relativePath: relative)
                    try await store.removeSubtree(folderPath: relative)
                    changed = true
                } else if isDirectory.boolValue {
                    try await rescanDirectory(url)
                    changed = true
                } else if LibraryBrowser.isSupportedTextFile(url) {
                    try await indexFileIfNeeded(at: url)
                    changed = true
                }
            } catch {
                // Index errors are recoverable; the next full scan reconciles.
            }
        }
        if changed {
            // Once per batch, not per path.
            try? await store.pruneOrphanTags()
            onChange()
        }
    }

    /// Re-syncs one directory (not recursive: FSEvents reports child
    /// directories separately when their contents change).
    private func rescanDirectory(_ directory: URL) async throws {
        guard let relativeDir = relativePath(of: directory) else { return }
        let onDisk = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        )) ?? []

        var present = Set<String>()
        for child in onDisk {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else { continue }
            guard !LibraryBrowser.isExcluded(child, showHidden: showHiddenFiles),
                  LibraryBrowser.isSupportedTextFile(child),
                  let relative = relativePath(of: child) else { continue }
            present.insert(relative)
            try await indexFileIfNeeded(at: child)
        }

        // Prune direct children of this directory that vanished.
        let indexed = try await store.files(inFolder: relativeDir)
        for record in indexed where !present.contains(record.relativePath) {
            let absolute = root.appendingPathComponent(record.relativePath)
            if !FileManager.default.fileExists(atPath: absolute.path) {
                try await store.removeFile(relativePath: record.relativePath)
            }
        }
    }

    // MARK: - Paths

    private func relativePath(of url: URL) -> String? {
        let canonical = AppSupportPaths.canonicalPath(of: url)
        if canonical == rootPath { return nil }
        guard canonical.hasPrefix(rootPath + "/") else { return nil }
        return String(canonical.dropFirst(rootPath.count + 1))
    }

    private func relativePathIsExcluded(_ relative: String) -> Bool {
        for component in relative.split(separator: "/") {
            if LibraryBrowser.excludedDirectoryNames.contains(String(component)) { return true }
            if !showHiddenFiles && component.hasPrefix(".") { return true }
        }
        return false
    }
}
