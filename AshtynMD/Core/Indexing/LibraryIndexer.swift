import Foundation

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

    init(
        root: URL,
        store: LibraryStore,
        showHiddenFiles: Bool = false,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.root = root
        self.rootPath = AppSupportPaths.canonicalPath(of: root)
        self.store = store
        self.showHiddenFiles = showHiddenFiles
        self.onChange = onChange
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
                await Task.yield()
            }
        }
        try await indexBatch(batch)
        try await store.removeFilesNotIn(seenPaths)
        onChange()
    }

    private func indexBatch(_ urls: [URL]) async throws {
        guard !urls.isEmpty else { return }
        for url in urls {
            try await indexFileIfNeeded(at: url)
        }
    }

    /// Indexes one file when its size/mtime differ from the stored row, or
    /// when the row is missing. Recognizes moves via the resource identifier.
    private func indexFileIfNeeded(at url: URL) async throws {
        guard let relative = relativePath(of: url),
              let disk = SaveCoordinator.diskState(of: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        if let existing = try await store.record(forRelativePath: relative) {
            let sameStamp = abs(existing.modifiedAt.timeIntervalSince1970 - disk.modificationDate.timeIntervalSince1970) < 0.001
            if sameStamp && existing.size == size { return }
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
        try await store.upsertFile(
            relativePath: relative,
            size: size,
            modifiedAt: disk.modificationDate,
            contentHash: hash,
            languageID: language,
            resourceID: disk.resourceID,
            content: content
        )
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

    private func handleEventPaths(_ paths: [String]) async {
        var changed = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let relative = relativePath(of: url) else { continue }
            if relativePathIsExcluded(relative) { continue }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            do {
                if !exists {
                    // Removed, or renamed away: prune this path (and subtree —
                    // we can't know whether it was a folder).
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
        if changed { onChange() }
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
