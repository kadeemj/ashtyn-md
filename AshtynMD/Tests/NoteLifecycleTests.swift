import Foundation
import Testing

@testable import AshtynMD

@Suite("Note lifecycle")
struct NoteLifecycleTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("archive and unarchive preserve the original relative path")
    func archiveRoundTrip() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = try write("Archived body", to: "Projects/note.md", in: root)
        let archived = try NoteLifecycle.archive(original, in: root)

        #expect(archived.path == root.appendingPathComponent(".archive/Projects/note.md").path)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(NoteLifecycle.originalRelativePath(ofArchivePath: ".archive/Projects/note.md") == "Projects/note.md")

        let restored = try NoteLifecycle.unarchive(archived, in: root)
        #expect(restored.path == original.path)
        #expect(String(data: try Data(contentsOf: restored), encoding: .utf8) == "Archived body")
    }

    @Test("trash writes a manifest and restores the exact source path")
    func trashRoundTrip() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try write("Keep me", to: "Inbox/meta.json", in: root)
        let trashed = try NoteLifecycle.trash(
            source,
            in: root,
            title: "Keep me",
            now: Date(timeIntervalSince1970: 123)
        )

        #expect(trashed.url.lastPathComponent == ".note-meta.json")
        #expect(trashed.metadata.originalRelativePath == "Inbox/meta.json")
        #expect(try NoteLifecycle.metadata(for: trashed.url) == trashed.metadata)
        #expect(!FileManager.default.fileExists(atPath: source.path))

        let restored = try NoteLifecycle.restore(trashed.url, in: root)
        #expect(restored.path == source.path)
        #expect(String(data: try Data(contentsOf: restored), encoding: .utf8) == "Keep me")
    }

    @Test("restore refuses to overwrite a newly created source file")
    func restoreCollision() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try write("Original", to: "note.md", in: root)
        let trashed = try NoteLifecycle.trash(source, in: root, title: "Original")
        _ = try write("Replacement", to: "note.md", in: root)

        do {
            _ = try NoteLifecycle.restore(trashed.url, in: root)
            Issue.record("restore unexpectedly overwrote the existing source")
        } catch let error as NoteLifecycle.LifecycleError {
            guard case .destinationAlreadyExists = error else {
                Issue.record("unexpected lifecycle error: \(error)")
                return
            }
        }
    }

    @Test("the dedicated indexer pass exposes archived and trashed notes")
    func lifecycleIndexing() async throws {
        let root = try makeRoot()
        let store = try LibraryStore(databaseURL: root.appendingPathComponent(".index-test.sqlite"))
        let indexer = LibraryIndexer(root: root, store: store, onChange: {})

        _ = try write("Active", to: "active.md", in: root)
        let archivedSource = try write("Archived", to: "archive-me.md", in: root)
        _ = try NoteLifecycle.archive(archivedSource, in: root)
        let trashedSource = try write("Trashed", to: "trash-me.md", in: root)
        _ = try NoteLifecycle.trash(trashedSource, in: root, title: "Trashed")

        try await indexer.fullScan()

        #expect(try await store.notes().map(\.relativePath) == ["active.md"])
        #expect(try await store.archivedNotes().map(\.relativePath) == [".archive/archive-me.md"])
        #expect(try await store.trashedNotes().map(\.trashedOriginPath) == ["trash-me.md"])

        await indexer.stop()
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }
}
