import Foundation
import Testing

@testable import AshtynMD

@Suite("Inbox folder")
struct InboxFolderTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("the inbox is created on demand")
    func createsOnDemand() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let inbox = try InboxFolder.ensureExists(in: root)
        #expect(inbox.lastPathComponent == "Inbox")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("creating it twice is harmless")
    func idempotent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try InboxFolder.ensureExists(in: root)
        let second = try InboxFolder.ensureExists(in: root)
        #expect(first == second)
    }

    @Test("an existing Inbox folder is adopted, not replaced")
    func adoptsExistingFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A user who already keeps notes in a folder called Inbox should find
        // that it simply *is* the Inbox — nothing created, nothing moved.
        let existing = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("Mine\n".utf8).write(to: existing.appendingPathComponent("note.md"))

        let inbox = try InboxFolder.ensureExists(in: root)
        #expect(inbox == existing)
        #expect(FileManager.default.fileExists(
            atPath: existing.appendingPathComponent("note.md").path
        ))
    }

    @Test("a file named Inbox falls back to the root rather than clobbering it")
    func fileNamedInbox() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a folder".utf8).write(to: root.appendingPathComponent("Inbox"))

        let target = try InboxFolder.ensureExists(in: root)
        #expect(target == root)
    }

    @Test("membership is a path prefix, needing nothing in the schema")
    func membership() {
        #expect(InboxFolder.contains(relativePath: "Inbox/note.md"))
        #expect(InboxFolder.contains(relativePath: "Inbox/Sub/note.md"))
        #expect(!InboxFolder.contains(relativePath: "note.md"))
        #expect(!InboxFolder.contains(relativePath: "Inboxes/note.md"))
        #expect(!InboxFolder.contains(relativePath: "Other/Inbox/note.md"))
    }
}

@Suite("Tag insertion")
struct TagInsertionTests {
    private func apply(_ tag: String, to text: String) -> String? {
        guard let edit = TagInsertion.plan(for: tag, in: text) else { return nil }
        return (text as NSString)
            .replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test("a tag is appended as its own block")
    func appendsBlock() {
        #expect(apply("#work", to: "Title\n\nbody") == "Title\n\nbody\n\n#work\n")
    }

    @Test("a tag joins a trailing pure-tag line")
    func joinsTagLine() {
        // Repeated drops should collect on one line rather than stacking blocks.
        #expect(apply("#home", to: "Title\n\nbody\n\n#work\n") == "Title\n\nbody\n\n#work #home\n")
    }

    @Test("a line with prose is not treated as a tag line")
    func prosePlusTagIsNotATagLine() {
        let result = apply("#home", to: "Title\n\nsome #work prose")
        #expect(result == "Title\n\nsome #work prose\n\n#home\n")
    }

    @Test("an already-tagged note is left alone")
    func noDuplicate() {
        #expect(TagInsertion.plan(for: "#work", in: "Title\n\n#work") == nil)
        #expect(TagInsertion.plan(for: "#Work", in: "Title\n\n#work") == nil)
    }

    @Test("a note already carrying a descendant is left alone")
    func descendantCovers() {
        // Adding #work to a note tagged #work/alpha would be redundant: the
        // ancestor closure already files it under #work.
        #expect(TagInsertion.plan(for: "#work", in: "Title\n\n#work/alpha") == nil)
    }

    @Test("a more specific tag is still added")
    func moreSpecificIsAdded() {
        #expect(apply("#work/alpha", to: "Title\n\n#work\n") == "Title\n\n#work #work/alpha\n")
    }

    @Test("the first line is never touched")
    func neverTouchesTitle() {
        // The first line is the title, and now also the filename.
        let result = apply("#work", to: "Just A Title")
        #expect(result?.hasPrefix("Just A Title") == true)
        #expect(result == "Just A Title\n\n#work\n")
    }

    @Test("an empty note gets a bare tag")
    func emptyNote() {
        #expect(apply("#work", to: "") == "#work\n")
    }

    @Test("insertion works in LF, which is the only in-memory form")
    func alwaysLF() {
        // LoadedTextFile normalizes to LF on load and reapplies the file's
        // original style on save, so this only ever sees LF and must not try
        // to guess otherwise.
        #expect(apply("#work", to: "Title\n\nbody") == "Title\n\nbody\n\n#work\n")
        #expect(apply("#work", to: "Title\n\nbody\n") == "Title\n\nbody\n\n#work\n")
    }
}

@Suite("Note list model")
@MainActor
struct NoteListModelTests {
    @Test("the list starts on the Inbox so launching means ready to capture")
    func defaultsToInbox() {
        #expect(NoteListModel().selection == .inbox)
    }

    @Test("changing selection clears the previous selection and notifies")
    func selectionChangeResets() {
        let model = NoteListModel()
        var notifications = 0
        model.onSelectionChange = { notifications += 1 }

        model.selectedPaths = ["a.md"]
        model.selection = .notes
        #expect(model.selectedPaths.isEmpty)
        #expect(notifications == 1)

        // Setting the same value again should not churn.
        model.selection = .notes
        #expect(notifications == 1)
    }

    @Test("changing sort order notifies")
    func sortChangeNotifies() {
        let model = NoteListModel()
        var notifications = 0
        model.onSelectionChange = { notifications += 1 }
        model.sortOrder = .titleAscending
        #expect(notifications == 1)
    }

    @Test("each selection has its own title and empty state")
    func titlesAndEmptyStates() {
        let model = NoteListModel()
        let cases: [(SidebarItem, String)] = [
            (.inbox, "Inbox"),
            (.notes, "Notes"),
            (.untagged, "Untagged"),
            (.todo, "To-Dos"),
            (.pinned, "Pinned"),
            (.favorites, "Favorites"),
            (.archive, "Archive"),
            (.trash, "Trash"),
            (.tag("work/alpha"), "#work/alpha"),
        ]
        for (item, expected) in cases {
            model.selection = item
            #expect(model.title() == expected)
            // Every state needs copy; a blank empty state reads as a bug.
            #expect(!model.emptyState.title.isEmpty)
            #expect(!model.emptyState.message.isEmpty)
        }
    }

    @Test("selected records are resolved from the listed notes")
    func selectedRecords() {
        let model = NoteListModel()
        #expect(model.selectedRecords.isEmpty)
        model.selectedPaths = ["missing.md"]
        // A stale path resolves to nothing rather than crashing.
        #expect(model.selectedRecords.isEmpty)
    }
}

@Suite("Tags model")
@MainActor
struct TagsModelTests {
    @Test("counts map onto the fixed sidebar rows")
    func countsForItems() {
        let model = TagsModel()
        // Empty by default; the point is that every fixed row asks for a count
        // and none of them trap.
        for item in [
            SidebarItem.inbox, .notes, .untagged, .todo, .pinned,
            .favorites, .archive, .trash,
        ] {
            #expect(model.count(for: item) == 0)
        }
        #expect(model.count(for: .search) == nil)
        #expect(model.count(for: .recents) == nil)
    }

    @Test("a tag node is found at any depth")
    func findsNestedNode() {
        let deep = TagNode(
            key: "work/alpha/beta", displayName: "beta", displayPath: "work/alpha/beta",
            count: 1, isPinned: false
        )
        let middle = TagNode(
            key: "work/alpha", displayName: "alpha", displayPath: "work/alpha",
            count: 2, isPinned: false, children: [deep]
        )
        let root = TagNode(
            key: "work", displayName: "work", displayPath: "work",
            count: 3, isPinned: true, children: [middle]
        )
        let model = TagsModel()
        model.setTreeForTesting([root])

        #expect(model.node(forKey: "work")?.count == 3)
        #expect(model.node(forKey: "work/alpha")?.count == 2)
        #expect(model.node(forKey: "work/alpha/beta")?.count == 1)
        #expect(model.node(forKey: "missing") == nil)
        #expect(model.count(for: .tag("work/alpha")) == 2)
    }
}
