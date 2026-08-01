import Foundation
import Testing

@testable import AshtynMD

@Suite("Tag rewriting")
struct TagRewriterTests {
    @Test("renaming a tag rewrites exact and descendant paths back-to-front")
    func renamesExactAndDescendants() throws {
        let source = "first #work second #work/alpha third #keep"
        let result = try TagRewriter.rewrite(source, oldKey: "work", replacement: "Projects")
        #expect(result == "first #Projects second #Projects/alpha third #keep")
    }

    @Test("deleting a tag removes the complete tag spans")
    func deletesTags() throws {
        let source = "before #work and #work/alpha after"
        let result = try TagRewriter.rewrite(source, oldKey: "work", replacement: nil)
        #expect(result == "before  and  after")
    }

    @Test("closing-hash tags preserve their syntax")
    func preservesClosingHashSyntax() throws {
        let source = "A #old project# and #keep"
        let result = try TagRewriter.rewrite(source, oldKey: "old project", replacement: "new project")
        #expect(result == "A #new project# and #keep")
    }

    @Test("masked code and invalid replacement paths are protected")
    func protectsGrammarBoundaries() throws {
        let source = "`#work` and #work"
        #expect(try TagRewriter.rewrite(source, oldKey: "work", replacement: "archive") == "`#work` and #archive")

        do {
            _ = try TagRewriter.rewrite("#work", oldKey: "work", replacement: "123")
            Issue.record("numeric-only replacement unexpectedly succeeded")
        } catch let error as TagRewriter.RewriteError {
            guard case .invalidTag = error else { Issue.record("unexpected error: \(error)"); return }
        }
    }

    @Test("a snapshot restores original bytes and is then consumed")
    func snapshotUndo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-tag-snapshot-\(UUID().uuidString)", isDirectory: true)
        let metadataRoot = AppSupportPaths.libraryDirectory(forRoot: root)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: metadataRoot)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let note = root.appendingPathComponent("note.md")
        let original = Data("before\r\n#work\r\n".utf8)
        try original.write(to: note)
        let first = try TagRewriteUndoStore.create(
            root: root,
            oldKey: "work",
            replacement: "archive",
            originals: [("note.md", original)],
            now: Date(timeIntervalSince1970: 100)
        )
        let later = Data("later\r\n".utf8)
        let second = try TagRewriteUndoStore.create(
            root: root,
            oldKey: "work",
            replacement: "archive",
            originals: [("note.md", later)],
            now: Date(timeIntervalSince1970: 200)
        )
        try Data("after\n".utf8).write(to: note)

        #expect(first != second)
        #expect(TagRewriteUndoStore.latest(in: root) == second)
        #expect(try TagRewriteUndoStore.restoreLatest(in: root) == ["note.md"])
        #expect(try Data(contentsOf: note) == later)
        #expect(TagRewriteUndoStore.latest(in: root) == first)
    }
}
