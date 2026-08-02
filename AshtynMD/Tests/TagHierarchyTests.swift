import Foundation
import Testing

@testable import AshtynMD

@Suite("Tag hierarchy")
struct TagHierarchyTests {
    /// Runs `body` against a store, closing SQLite before the directory is
    /// removed — teardown races the WAL files otherwise.
    private func withStore<T>(_ body: (LibraryStore) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagHierarchyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        do {
            let result = try await body(store)
            try await store.close()
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @discardableResult
    private func add(
        _ store: LibraryStore,
        _ path: String,
        _ text: String,
        modified: TimeInterval = 1_700_000_000
    ) async throws -> Int64 {
        var update = FileIndexUpdate(
            relativePath: path,
            size: Int64(text.utf8.count),
            modifiedAt: Date(timeIntervalSince1970: modified),
            languageID: .markdown,
            content: text
        )
        update.createdAt = Date(timeIntervalSince1970: modified - 1_000)
        update.parsed = MarkdownMetadata.parse(text)
        return try await store.upsertFile(update)
    }

    // MARK: - Closure rows

    @Test("a nested tag also files the note under every ancestor")
    func ancestorsAreIndexed() async throws {
        try await withStore { store in
            try await add(store, "a.md", "Note\n\n#work/alpha/beta")

            // Storing ancestors turns "notes under #work" into an equality join
            // rather than a LIKE scan or a recursive query.
            #expect(try await store.notes(taggedWith: "work").count == 1)
            #expect(try await store.notes(taggedWith: "work/alpha").count == 1)
            #expect(try await store.notes(taggedWith: "work/alpha/beta").count == 1)
            #expect(try await store.notes(taggedWith: "work/other").isEmpty)
        }
    }

    @Test("a note counts once under a tag even with several matching tags")
    func noDoubleCounting() async throws {
        try await withStore { store in
            try await add(store, "a.md", "Note\n\n#work/alpha and #work/beta and #work")

            #expect(try await store.notes(taggedWith: "work").count == 1)
            let tree = try await store.tagTree()
            let work = tree.first { $0.key == "work" }
            #expect(work?.count == 1)
        }
    }

    @Test("the tag tree nests by path")
    func tagTreeNests() async throws {
        try await withStore { store in
            try await add(store, "a.md", "A\n\n#work/alpha")
            try await add(store, "b.md", "B\n\n#work/beta")
            try await add(store, "c.md", "C\n\n#home")

            let tree = try await store.tagTree()
            #expect(tree.map(\.key).sorted() == ["home", "work"])
            let work = tree.first { $0.key == "work" }
            #expect(work?.children.map(\.key).sorted() == ["work/alpha", "work/beta"])
            #expect(work?.count == 2)
            #expect(work?.displayName == "work")
            #expect(work?.children.first?.displayName == "alpha")
        }
    }

    @Test("tag counts include descendants")
    func countsIncludeDescendants() async throws {
        try await withStore { store in
            try await add(store, "a.md", "A\n\n#work/alpha")
            try await add(store, "b.md", "B\n\n#work/alpha/deep")
            try await add(store, "c.md", "C\n\n#work")

            let tree = try await store.tagTree()
            #expect(tree.first { $0.key == "work" }?.count == 3)
            let alpha = tree.first { $0.key == "work" }?.children.first { $0.key == "work/alpha" }
            #expect(alpha?.count == 2)
        }
    }

    @Test("case differences collapse onto one tag")
    func caseFolding() async throws {
        try await withStore { store in
            try await add(store, "a.md", "A\n\n#Work")
            try await add(store, "b.md", "B\n\n#work")

            let tree = try await store.tagTree()
            #expect(tree.count == 1)
            #expect(tree.first?.count == 2)
        }
    }

    // MARK: - Re-indexing

    @Test("removing a tag from a note removes the row")
    func tagRemoval() async throws {
        try await withStore { store in
            try await add(store, "a.md", "A\n\n#work #home")
            #expect(try await store.tagTree().count == 2)

            try await add(store, "a.md", "A\n\n#work")
            #expect(try await store.notes(taggedWith: "home").isEmpty)
        }
    }

    @Test("orphan tags are pruned but pinned ones survive")
    func pruning() async throws {
        try await withStore { store in
            try await add(store, "a.md", "A\n\n#work #home")
            try await store.setTagPinned(true, key: "home")
            try await add(store, "a.md", "A\n\nno tags now")

            let pruned = try await store.pruneOrphanTags()
            #expect(pruned == 1)
            let tree = try await store.tagTree()
            // A pinned tag with no notes is deliberately kept: the user pinned it.
            #expect(tree.map(\.key) == ["home"])
            #expect(tree.first?.count == 0)
            #expect(tree.first?.isPinned == true)
        }
    }

    @Test("deleting a file cascades its tag rows")
    func cascadeOnDelete() async throws {
        try await withStore { store in
            try await add(store, "a.md", "A\n\n#work")
            try await store.removeFile(relativePath: "a.md")
            _ = try await store.pruneOrphanTags()
            #expect(try await store.tagTree().isEmpty)
        }
    }

    // MARK: - Metadata columns

    @Test("title, excerpt, and counts land on the row")
    func metadataColumns() async throws {
        try await withStore { store in
            try await add(
                store, "a.md",
                "Grocery Run\n\nmilk and eggs\n\n- [ ] buy milk\n- [x] buy eggs"
            )
            let record = try await store.record(forRelativePath: "a.md")
            #expect(record?.title == "Grocery Run")
            #expect(record?.titleKey == "grocery run")
            #expect(record?.excerpt.contains("milk and eggs") == true)
            #expect(record?.todoTotal == 2)
            #expect(record?.todoOpen == 1)
            #expect((record?.wordCount ?? 0) > 0)
            #expect(record?.createdAt != nil)
            #expect(record?.reindexPending == false)
        }
    }

    @Test("wiki links are recorded and resolve by title")
    func wikiLinks() async throws {
        try await withStore { store in
            try await add(store, "target.md", "Weekly Review\n\nthe target note")
            try await add(store, "source.md", "Source\n\nsee [[Weekly Review]]")

            let resolved = try await store.resolveWikiLink("weekly review")
            #expect(resolved.map(\.relativePath) == ["target.md"])

            let target = try await store.record(forRelativePath: "target.md")!
            let backlinks = try await store.backlinks(toTitleKey: "weekly review", excluding: target.id)
            #expect(backlinks.map(\.relativePath) == ["source.md"])
        }
    }

    @Test("backlinks follow a renamed target because they resolve by title")
    func backlinksSurviveRename() async throws {
        try await withStore { store in
            try await add(store, "target.md", "Weekly Review\n\nbody")
            try await add(store, "source.md", "Source\n\nsee [[Weekly Review]]")

            // The links table stores no target file id on purpose, so moving the
            // target needs no maintenance at all.
            try await store.updatePath(ofFileWithResourceID: "missing", to: "unused.md")
            var update = FileIndexUpdate(
                relativePath: "Archive/Weekly Review.md",
                size: 10,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                languageID: .markdown,
                content: "Weekly Review\n\nbody"
            )
            update.parsed = MarkdownMetadata.parse("Weekly Review\n\nbody")
            _ = try await store.upsertFile(update)
            try await store.removeFile(relativePath: "target.md")

            let resolved = try await store.resolveWikiLink("weekly review")
            #expect(resolved.map(\.relativePath) == ["Archive/Weekly Review.md"])
        }
    }

    @Test("an ambiguous wiki link returns every candidate")
    func ambiguousWikiLink() async throws {
        try await withStore { store in
            try await add(store, "one/Meeting.md", "Meeting\n\nfirst")
            try await add(store, "two/Meeting.md", "Meeting\n\nsecond")
            #expect(try await store.resolveWikiLink("meeting").count == 2)
        }
    }

    @Test("title candidates return every titled note regardless of query")
    func titleCandidatesReturnsAllTitledNotes() async throws {
        try await withStore { store in
            try await add(store, "a.md", "Weekly Review\n\nbody")
            try await add(store, "b.md", "Groceries\n\nbody")
            try await add(store, "untitled.md", "")

            let candidates = try await store.titleCandidates(limit: 10)
            #expect(candidates.map(\.title).sorted() == ["Groceries", "Weekly Review"])
        }
    }

    @Test("title candidates respect the limit and recency order")
    func titleCandidatesRespectsLimitAndOrder() async throws {
        try await withStore { store in
            try await add(store, "old.md", "Old Note\n\nbody", modified: 1_700_000_000)
            try await add(store, "new.md", "New Note\n\nbody", modified: 1_700_000_100)

            let candidates = try await store.titleCandidates(limit: 1)
            #expect(candidates.map(\.title) == ["New Note"])
        }
    }

    @Test("wiki links resolve to titles the candidate window leaves out")
    func resolveWikiLinkSeesPastTheCandidateWindow() async throws {
        try await withStore { store in
            try await add(store, "old.md", "Old Note\n\nbody", modified: 1_700_000_000)
            try await add(store, "new.md", "New Note\n\nbody", modified: 1_700_000_100)

            // The candidate pool is a bounded recency window (500 in
            // production), so an older note can fall out of it entirely.
            let candidates = try await store.titleCandidates(limit: 1)
            #expect(!candidates.map(\.title).contains("Old Note"))

            // resolveWikiLink is unbounded, which is what lets the wiki-link
            // popover tell "no ranked match" apart from "no such note" before
            // creating a duplicate.
            let resolved = try await store.resolveWikiLink(
                MarkdownMetadata.foldTitle("Old Note")
            )
            #expect(resolved.map(\.title) == ["Old Note"])
        }
    }

    @Test("primary tag is the lexicographically-first direct tag")
    func primaryTagIsLexicographicallyFirst() async throws {
        try await withStore { store in
            let fileID = try await add(store, "a.md", "Tagged\n\n#reading #work/alpha")
            let untaggedID = try await add(store, "b.md", "Untagged\n\nno tags")

            #expect(try await store.primaryTag(forFileID: fileID) == "reading")
            #expect(try await store.primaryTag(forFileID: untaggedID) == nil)
        }
    }

    // MARK: - Counts and sorting

    @Test("the sidebar counts come from one query")
    func libraryCounts() async throws {
        try await withStore { store in
            try await add(store, "tagged.md", "Tagged\n\n#work")
            try await add(store, "plain.md", "Plain\n\nno tags")
            try await add(store, "todo.md", "Todo\n\n- [ ] something")
            try await store.setPinned(true, relativePath: "plain.md")
            try await store.setFavorite(true, relativePath: "tagged.md")

            let counts = try await store.counts()
            #expect(counts.notes == 3)
            #expect(counts.untagged == 2)
            #expect(counts.todo == 1)
            #expect(counts.pinned == 1)
            #expect(counts.favorites == 1)
            #expect(counts.archived == 0)
            #expect(counts.trashed == 0)
        }
    }

    @Test("created-date sorting uses the real creation time")
    func createdSort() async throws {
        try await withStore { store in
            // Inserted oldest-first, so an id-ordered proxy would get this wrong.
            try await add(store, "old.md", "Old\n\nbody", modified: 1_600_000_000)
            try await add(store, "new.md", "New\n\nbody", modified: 1_800_000_000)

            let byCreated = try await store.notes(sortedBy: .createdDescending)
            #expect(byCreated.map(\.relativePath) == ["new.md", "old.md"])
        }
    }

    @Test("title sorting is case insensitive")
    func titleSort() async throws {
        try await withStore { store in
            try await add(store, "a.md", "banana\n\nbody")
            try await add(store, "b.md", "Apple\n\nbody")

            let sorted = try await store.notes(sortedBy: .titleAscending)
            #expect(sorted.map(\.title) == ["Apple", "banana"])
        }
    }

    @Test("pinned notes float to the top of every sort")
    func pinnedFloat() async throws {
        try await withStore { store in
            try await add(store, "a.md", "Aaa\n\nbody", modified: 1_800_000_000)
            try await add(store, "z.md", "Zzz\n\nbody", modified: 1_600_000_000)
            try await store.setPinned(true, relativePath: "z.md")

            for order in [LibraryStore.SortOrder.modifiedDescending, .titleAscending, .nameAscending] {
                let sorted = try await store.notes(sortedBy: order)
                #expect(sorted.first?.relativePath == "z.md", "order \(order)")
            }
        }
    }

    @Test("untagged and todo lists filter correctly")
    func smartLists() async throws {
        try await withStore { store in
            try await add(store, "tagged.md", "Tagged\n\n#work")
            try await add(store, "plain.md", "Plain\n\nnothing")
            try await add(store, "todo.md", "Todo\n\n- [ ] open one")
            try await add(store, "done.md", "Done\n\n- [x] closed")

            #expect(try await store.untaggedNotes().map(\.relativePath).sorted()
                == ["done.md", "plain.md", "todo.md"])
            #expect(try await store.todoNotes().map(\.relativePath) == ["todo.md"])
        }
    }

    @Test("non-markdown files get their filename as a title and no tags")
    func nonMarkdownFiles() async throws {
        try await withStore { store in
            // `#` is a comment in shell, Python, and YAML, so parsing those for
            // tags would fill the sidebar with #!/usr/bin and # TODO.
            var update = FileIndexUpdate(
                relativePath: "script.sh",
                size: 30,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                languageID: .shell,
                content: "#!/bin/sh\n# TODO fix this\n"
            )
            update.parsed = nil
            _ = try await store.upsertFile(update)

            #expect(try await store.tagTree().isEmpty)
            #expect(try await store.record(forRelativePath: "script.sh")?.title == "script.sh")
        }
    }

    @Test("the legacy upsert signature still works")
    func legacyUpsertShim() async throws {
        try await withStore { store in
            // Kept so the existing LibraryStoreTests did not all have to be
            // rewritten inside one task.
            _ = try await store.upsertFile(
                relativePath: "plain.txt",
                size: 10,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                contentHash: nil,
                languageID: .plainText,
                resourceID: nil,
                content: "hello"
            )
            #expect(try await store.record(forRelativePath: "plain.txt") != nil)
        }
    }
}
