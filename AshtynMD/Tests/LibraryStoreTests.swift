import Foundation
import Testing
@testable import AshtynMD

private func makeStoreDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ashtyn-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeStore(in directory: URL) throws -> LibraryStore {
    try LibraryStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
}

private func withTemporaryStore<T>(
    _ body: (URL, LibraryStore) async throws -> T
) async throws -> T {
    let directory = try makeStoreDirectory()
    let store = try makeStore(in: directory)
    do {
        let result = try await body(directory, store)
        try await store.close()
        try FileManager.default.removeItem(at: directory)
        return result
    } catch {
        try? await store.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

@Suite("Library store")
struct LibraryStoreTests {
    @Test func explicitCloseIsIdempotentAndRejectsNewStatements() throws {
        let dir = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try SQLiteDatabase(
            path: dir.appendingPathComponent("library.sqlite").path
        )

        try database.executeScript("CREATE TABLE example (value TEXT)")
        try database.close()
        try database.close()

        #expect(throws: SQLiteError.self) {
            try database.executeScript("SELECT 1")
        }
    }

    @Test func createsSchemaAtVersionOne() async throws {
        try await withTemporaryStore { _, store in
            let count = try await store.fileCount()
            #expect(count == 0)
        }
    }

    @Test func upsertInsertsThenUpdates() async throws {
        try await withTemporaryStore { _, store in
            let id = try await store.upsertFile(
                relativePath: "notes/hello.md", size: 10,
                modifiedAt: Date(timeIntervalSince1970: 100),
                contentHash: "aaa", languageID: .markdown,
                resourceID: "dev:1", content: "hello world"
            )
            #expect(try await store.fileCount() == 1)

            let updatedID = try await store.upsertFile(
                relativePath: "notes/hello.md", size: 20,
                modifiedAt: Date(timeIntervalSince1970: 200),
                contentHash: "bbb", languageID: .markdown,
                resourceID: "dev:1", content: "hello again"
            )
            #expect(id == updatedID)
            #expect(try await store.fileCount() == 1)

            let record = try await store.record(forRelativePath: "notes/hello.md")
            #expect(record?.size == 20)
            #expect(record?.contentHash == "bbb")
        }
    }

    @Test func folderListingIsDirectChildrenOnly() async throws {
        try await withTemporaryStore { _, store in
            for path in ["a.md", "sub/b.md", "sub/deep/c.md"] {
                try await store.upsertFile(
                    relativePath: path, size: 1, modifiedAt: Date(),
                    contentHash: nil, languageID: .markdown, resourceID: nil, content: ""
                )
            }
            let rootFiles = try await store.files(inFolder: "")
            #expect(rootFiles.map(\.relativePath) == ["a.md"])
            let subFiles = try await store.files(inFolder: "sub")
            #expect(subFiles.map(\.relativePath) == ["sub/b.md"])
        }
    }

    @Test func favoritesAndRecents() async throws {
        try await withTemporaryStore { _, store in
            for path in ["one.md", "two.md"] {
                try await store.upsertFile(
                    relativePath: path, size: 1, modifiedAt: Date(),
                    contentHash: nil, languageID: .markdown, resourceID: nil, content: ""
                )
            }
            try await store.setFavorite(true, relativePath: "two.md")
            #expect(try await store.favorites().map(\.relativePath) == ["two.md"])

            try await store.markOpened(relativePath: "one.md", at: Date(timeIntervalSince1970: 100))
            try await store.markOpened(relativePath: "two.md", at: Date(timeIntervalSince1970: 200))
            #expect(try await store.recents().map(\.relativePath) == ["two.md", "one.md"])
        }
    }

    @Test func searchFindsTitleAndContent() async throws {
        try await withTemporaryStore { _, store in
            try await store.upsertFile(
                relativePath: "recipes/pasta.md", size: 1, modifiedAt: Date(),
                contentHash: nil, languageID: .markdown, resourceID: nil,
                content: "Boil the spaghetti for nine minutes."
            )
            try await store.upsertFile(
                relativePath: "journal/today.md", size: 1, modifiedAt: Date(),
                contentHash: nil, languageID: .markdown, resourceID: nil,
                content: "Wrote some Swift code."
            )

            let byContent = try await store.search("spaghetti")
            #expect(byContent.map(\.record.relativePath) == ["recipes/pasta.md"])

            let byTitle = try await store.search("pasta")
            #expect(byTitle.map(\.record.relativePath) == ["recipes/pasta.md"])

            let prefix = try await store.search("spagh")
            #expect(prefix.count == 1)

            // FTS5 operators must not leak through.
            let hostile = try await store.search("\"unbalanced OR NEAR(")
            #expect(hostile.isEmpty)
        }
    }

    @Test func renameViaResourceIDKeepsIdentity() async throws {
        try await withTemporaryStore { _, store in
            let id = try await store.upsertFile(
                relativePath: "old.md", size: 1, modifiedAt: Date(),
                contentHash: nil, languageID: .markdown,
                resourceID: "dev:42", content: "movable content"
            )
            try await store.setFavorite(true, relativePath: "old.md")
            try await store.updatePath(ofFileWithResourceID: "dev:42", to: "folder/new.md")

            #expect(try await store.record(forRelativePath: "old.md") == nil)
            let moved = try await store.record(forRelativePath: "folder/new.md")
            #expect(moved?.id == id)
            #expect(moved?.isFavorite == true)
            #expect(moved?.name == "new.md")

            // FTS row followed the move.
            let results = try await store.search("movable")
            #expect(results.map(\.record.relativePath) == ["folder/new.md"])
        }
    }

    @Test func removeSubtreePrunesEverythingUnderneath() async throws {
        try await withTemporaryStore { _, store in
            for path in ["keep.md", "gone/a.md", "gone/deep/b.md", "gone.md"] {
                try await store.upsertFile(
                    relativePath: path, size: 1, modifiedAt: Date(),
                    contentHash: nil, languageID: .markdown, resourceID: nil, content: ""
                )
            }
            try await store.removeSubtree(folderPath: "gone")
            let remaining = try await store.allFiles().map(\.relativePath).sorted()
            #expect(remaining == ["gone.md", "keep.md"])
        }
    }

    @Test func pruneAgainstPresentSet() async throws {
        try await withTemporaryStore { _, store in
            for path in ["a.md", "b.md", "c.md"] {
                try await store.upsertFile(
                    relativePath: path, size: 1, modifiedAt: Date(),
                    contentHash: nil, languageID: .markdown, resourceID: nil, content: ""
                )
            }
            try await store.removeFilesNotIn(["a.md", "c.md"])
            let remaining = try await store.allFiles().map(\.relativePath).sorted()
            #expect(remaining == ["a.md", "c.md"])
        }
    }

    @Test func viewStateAndAppStateRoundTrip() async throws {
        try await withTemporaryStore { _, store in
            let id = try await store.upsertFile(
                relativePath: "doc.md", size: 1, modifiedAt: Date(),
                contentHash: nil, languageID: .markdown, resourceID: nil, content: ""
            )
            var state = FileViewState()
            state.cursorLocation = 42
            state.scrollOffset = 123.5
            state.previewMode = "split"
            try await store.saveViewState(state, forFileID: id)
            #expect(try await store.viewState(forFileID: id) == state)

            try await store.setAppState("{\"tabs\":[]}", forKey: "windowState.v1")
            #expect(try await store.appState(forKey: "windowState.v1") == "{\"tabs\":[]}")
            try await store.setAppState("updated", forKey: "windowState.v1")
            #expect(try await store.appState(forKey: "windowState.v1") == "updated")
        }
    }

    @Test func persistsAcrossReopen() async throws {
        try await withTemporaryStore { dir, store in
            try await store.upsertFile(
                relativePath: "persist.md", size: 5, modifiedAt: Date(),
                contentHash: "h", languageID: .markdown, resourceID: nil, content: "durable"
            )
            try await store.close()

            let reopened = try makeStore(in: dir)
            do {
                #expect(try await reopened.record(forRelativePath: "persist.md")?.contentHash == "h")
                #expect(try await reopened.search("durable").count == 1)
                try await reopened.close()
            } catch {
                try? await reopened.close()
                throw error
            }
        }
    }
}
