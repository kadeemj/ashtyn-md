import Foundation
import Testing

@testable import AshtynMD

/// Covers what the indexer derives from a note's body, and the rename-identity
/// fix that auto-naming depends on.
@Suite("Library indexer metadata")
struct LibraryIndexerMetadataTests {
    private func withLibrary<T>(
        _ body: (URL, LibraryStore, LibraryIndexer) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-index-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LibraryStore(
            databaseURL: root.appendingPathComponent(".index-test.sqlite")
        )
        let indexer = LibraryIndexer(root: root, store: store, onChange: {})
        do {
            let result = try await body(root, store, indexer)
            await indexer.stop()
            try await store.close()
            try FileManager.default.removeItem(at: root)
            return result
        } catch {
            await indexer.stop()
            try? await store.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func write(_ text: String, to name: String, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Derived metadata

    @Test("a markdown note gets a title, excerpt, tags, and counts")
    func markdownMetadata() async throws {
        try await withLibrary { root, store, indexer in
            try write(
                """
                Grocery Run

                Need to pick up a few things #home/errands

                - [ ] milk
                - [x] eggs
                """,
                to: "note.md", in: root
            )
            try await indexer.fullScan()

            let record = try await store.record(forRelativePath: "note.md")
            #expect(record?.title == "Grocery Run")
            #expect(record?.titleKey == "grocery run")
            #expect(record?.excerpt.contains("Need to pick up") == true)
            #expect(record?.todoTotal == 2)
            #expect(record?.todoOpen == 1)
            #expect((record?.wordCount ?? 0) > 0)
            #expect(record?.createdAt != nil)

            let tree = try await store.tagTree()
            #expect(tree.map(\.key) == ["home"])
            #expect(tree.first?.children.map(\.key) == ["home/errands"])
        }
    }

    @Test("a non-markdown file is never parsed for tags or a title")
    func nonMarkdownIsNotParsed() async throws {
        try await withLibrary { root, store, indexer in
            // `#` is a comment in shell, Python, and YAML, so parsing these
            // would fill the sidebar with #!/usr/bin and # TODO. And a Swift
            // file's first line makes a terrible auto-filename.
            try write("#!/bin/sh\n# TODO tidy this up\necho hi\n", to: "run.sh", in: root)
            try write("# comment\nvalue = 1\n", to: "conf.yaml", in: root)
            try write("import Foundation\nlet x = 1\n", to: "Code.swift", in: root)
            try await indexer.fullScan()

            #expect(try await store.tagTree().isEmpty)
            #expect(try await store.record(forRelativePath: "run.sh")?.title == "run.sh")
            #expect(try await store.record(forRelativePath: "Code.swift")?.title == "Code.swift")
        }
    }

    @Test("editing a note refreshes its derived metadata")
    func metadataRefreshes() async throws {
        try await withLibrary { root, store, indexer in
            try write("First Title\n\n#one", to: "note.md", in: root)
            try await indexer.fullScan()
            #expect(try await store.record(forRelativePath: "note.md")?.title == "First Title")

            // A new mtime is required, or the scan short-circuits by design.
            try write("Second Title\n\n#two", to: "note.md", in: root)
            let url = root.appendingPathComponent("note.md")
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path
            )
            try await indexer.fullScan()

            #expect(try await store.record(forRelativePath: "note.md")?.title == "Second Title")
            _ = try await store.pruneOrphanTags()
            #expect(try await store.tagTree().map(\.key) == ["two"])
        }
    }

    @Test("orphan tags are pruned once per scan")
    func pruningRunsAfterScan() async throws {
        try await withLibrary { root, store, indexer in
            try write("A\n\n#gone", to: "a.md", in: root)
            try await indexer.fullScan()
            #expect(try await store.tagTree().map(\.key) == ["gone"])

            try FileManager.default.removeItem(at: root.appendingPathComponent("a.md"))
            try await indexer.fullScan()
            // fullScan prunes after reconciling, so no stale tag survives.
            #expect(try await store.tagTree().isEmpty)
        }
    }

    @Test("a reindex-pending row is revisited even when size and mtime match")
    func reindexPendingForcesWork() async throws {
        try await withLibrary { root, store, indexer in
            try write("Titled Note\n\nbody", to: "note.md", in: root)
            try await indexer.fullScan()
            #expect(try await store.record(forRelativePath: "note.md")?.title == "Titled Note")

            // Simulate what the v2 migration leaves behind: correct size and
            // mtime, but empty derived columns.
            try await store.markReindexPendingForTesting(relativePath: "note.md")
            #expect(try await store.record(forRelativePath: "note.md")?.title == "")

            try await indexer.fullScan()
            #expect(try await store.record(forRelativePath: "note.md")?.title == "Titled Note")
            #expect(try await store.record(forRelativePath: "note.md")?.reindexPending == false)
        }
    }

    @Test("indexing progress is reported per batch")
    func progressReporting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-index-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LibraryStore(
            databaseURL: root.appendingPathComponent(".index-test.sqlite")
        )
        let collector = ProgressCollector()
        let indexer = LibraryIndexer(
            root: root,
            store: store,
            onChange: {},
            onProgress: { progress in collector.record(progress) }
        )
        defer {
            Task { await indexer.stop() }
        }
        do {
            for index in 0..<5 {
                try Data("Note \(index)\n\nbody".utf8)
                    .write(to: root.appendingPathComponent("note-\(index).md"))
            }
            try await indexer.fullScan()
            #expect(collector.scannedValues().last == 5)
            try await store.close()
            try FileManager.default.removeItem(at: root)
        } catch {
            try? await store.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    // MARK: - Rename identity

    @Test("renaming a favorited note preserves its id, favorite, and view state")
    func renamePreservesIdentity() async throws {
        try await withLibrary { root, store, indexer in
            try write("Original\n\nbody", to: "note.md", in: root)
            try await indexer.fullScan()

            let before = try await store.record(forRelativePath: "note.md")!
            try await store.setFavorite(true, relativePath: "note.md")
            try await store.markOpened(relativePath: "note.md")
            try await store.saveViewState(
                FileViewState(cursorLocation: 17), forFileID: before.id
            )

            try FileManager.default.moveItem(
                at: root.appendingPathComponent("note.md"),
                to: root.appendingPathComponent("renamed.md")
            )

            // The batch deliberately lists the vanished path first. Before the
            // fix this order deleted the row and reinserted a fresh one, losing
            // the id, the favorite, recents, and the view state. Rare when
            // renames are rare — constant once filenames follow titles.
            await indexer.handleEventPathsForTesting([
                root.appendingPathComponent("note.md").path,
                root.appendingPathComponent("renamed.md").path,
            ])

            let after = try await store.record(forRelativePath: "renamed.md")
            #expect(after != nil)
            #expect(after?.id == before.id)
            #expect(after?.isFavorite == true)
            #expect(after?.lastOpenedAt != nil)
            #expect(try await store.viewState(forFileID: before.id)?.cursorLocation == 17)
            #expect(try await store.record(forRelativePath: "note.md") == nil)
        }
    }

    @Test("applyRename repoints the row so the later event batch is a no-op")
    func applyRenameIsIdempotent() async throws {
        try await withLibrary { root, store, indexer in
            try write("Original\n\nbody", to: "note.md", in: root)
            try await indexer.fullScan()
            let before = try await store.record(forRelativePath: "note.md")!
            try await store.setFavorite(true, relativePath: "note.md")

            try FileManager.default.moveItem(
                at: root.appendingPathComponent("note.md"),
                to: root.appendingPathComponent("Renamed Title.md")
            )
            // The rename coordinator tells the index immediately, so no
            // suppression state or timers are needed.
            try await indexer.applyRename(from: "note.md", to: "Renamed Title.md")

            #expect(try await store.record(forRelativePath: "Renamed Title.md")?.id == before.id)

            // Replaying the event batch afterwards must change nothing.
            await indexer.handleEventPathsForTesting([
                root.appendingPathComponent("note.md").path,
                root.appendingPathComponent("Renamed Title.md").path,
            ])
            let after = try await store.record(forRelativePath: "Renamed Title.md")
            #expect(after?.id == before.id)
            #expect(after?.isFavorite == true)
        }
    }

    @Test("a genuinely deleted file is still pruned")
    func deletionStillPrunes() async throws {
        try await withLibrary { root, store, indexer in
            try write("Doomed\n\nbody", to: "note.md", in: root)
            try await indexer.fullScan()
            #expect(try await store.record(forRelativePath: "note.md") != nil)

            try FileManager.default.removeItem(at: root.appendingPathComponent("note.md"))
            await indexer.handleEventPathsForTesting([
                root.appendingPathComponent("note.md").path
            ])
            #expect(try await store.record(forRelativePath: "note.md") == nil)
        }
    }

    @Test("a deleted folder still prunes its subtree")
    func folderDeletionPrunesSubtree() async throws {
        try await withLibrary { root, store, indexer in
            try write("One\n\nbody", to: "Sub/one.md", in: root)
            try write("Two\n\nbody", to: "Sub/two.md", in: root)
            try await indexer.fullScan()
            #expect(try await store.fileCount() == 2)

            try FileManager.default.removeItem(at: root.appendingPathComponent("Sub"))
            await indexer.handleEventPathsForTesting([
                root.appendingPathComponent("Sub").path
            ])
            #expect(try await store.fileCount() == 0)
        }
    }
}

/// Collects progress callbacks from the indexer, which fire off the main actor.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ progress: IndexingProgress) {
        lock.lock()
        values.append(progress.scanned)
        lock.unlock()
    }

    func scannedValues() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
