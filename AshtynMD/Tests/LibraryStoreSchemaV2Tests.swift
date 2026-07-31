import Foundation
import Testing

@testable import AshtynMD

/// Upgrade tests for the schema v2 migration.
///
/// The v1 script is inlined verbatim rather than referenced, because it is
/// history: it has to keep describing what shipped even as `migrate` changes.
@Suite("Library store schema v2")
struct LibraryStoreSchemaV2Tests {
    private static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        relative_path TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        size INTEGER NOT NULL DEFAULT 0,
        mtime REAL NOT NULL DEFAULT 0,
        content_hash TEXT,
        language TEXT NOT NULL DEFAULT 'plainText',
        resource_id TEXT,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        last_opened_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_files_resource ON files(resource_id);
    CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
        name, relative_path, content,
        tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TABLE IF NOT EXISTS view_state (
        file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
        state_json TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS app_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """

    /// Runs `body` against a store, closing SQLite before the directory is
    /// removed — teardown races the WAL files otherwise.
    private func withMigratedStore<T>(
        seed: Bool,
        _ body: (LibraryStore) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaV2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        if seed { try seedVersionOneDatabase(at: url) }

        let store = try LibraryStore(databaseURL: url)
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

    /// Writes a populated v1 database, exactly as a shipped build would leave it.
    private func seedVersionOneDatabase(at url: URL) throws {
        let database = try SQLiteDatabase(path: url.path)
        try database.executeScript("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try database.executeScript(Self.schemaV1)
        database.userVersion = 1

        try database.run("""
            INSERT INTO files (relative_path, name, size, mtime, content_hash, language,
                               resource_id, is_favorite, last_opened_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            """, [
                .text("Notes/Kept.md"), .text("Kept.md"), .integer(120),
                .double(1_700_000_000), .text("abc"), .text("markdown"),
                .text("inode-1"), .integer(1), .double(1_700_000_500),
            ])
        let fileID = database.lastInsertRowID
        try database.run(
            "INSERT INTO files_fts (rowid, name, relative_path, content) VALUES (?,?,?,?)",
            [.integer(fileID), .text("Kept.md"), .text("Notes/Kept.md"), .text("old content")]
        )
        try database.run(
            "INSERT INTO view_state (file_id, state_json) VALUES (?,?)",
            [.integer(fileID), .text("{\"cursorLocation\":42,\"selectionLength\":0," +
                "\"scrollOffset\":10,\"previewScrollOffset\":0}")]
        )
        try database.run(
            "INSERT INTO app_state (key, value) VALUES (?,?)",
            [.text("windowState.v1"), .text("{}")]
        )
        try database.close()
    }

    private func add(
        _ store: LibraryStore,
        _ path: String,
        _ text: String
    ) async throws {
        var update = FileIndexUpdate(
            relativePath: path,
            size: Int64(text.utf8.count),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            languageID: .markdown,
            content: text
        )
        update.parsed = MarkdownMetadata.parse(text)
        _ = try await store.upsertFile(update)
    }

    // MARK: - Migration

    @Test("opening a v1 database migrates it to v2")
    func migratesToVersionTwo() async throws {
        try await withMigratedStore(seed: true) { (store: LibraryStore) async throws -> Void in
            #expect(try await store.schemaVersionOnDisk() == LibraryStore.schemaVersion)
            #expect(LibraryStore.schemaVersion == 2)
        }
    }

    @Test("the migration preserves favorites, recents, and view state")
    func migrationPreservesUserState() async throws {
        try await withMigratedStore(seed: true) { (store: LibraryStore) async throws -> Void in
            let record = try await store.record(forRelativePath: "Notes/Kept.md")
            #expect(record?.isFavorite == true)
            #expect(record?.lastOpenedAt != nil)
            #expect(record?.resourceID == "inode-1")

            let state = try await store.viewState(forFileID: record!.id)
            #expect(state?.cursorLocation == 42)
            #expect(try await store.appState(forKey: "windowState.v1") == "{}")
        }
    }

    @Test("existing rows are flagged for reindexing")
    func existingRowsNeedReindex() async throws {
        try await withMigratedStore(seed: true) { (store: LibraryStore) async throws -> Void in
            // The FTS table was dropped and rebuilt and every new column sits
            // at its default, so the indexer has to revisit every file.
            let record = try await store.record(forRelativePath: "Notes/Kept.md")
            #expect(record?.reindexPending == true)
            #expect(record?.title == "")
            #expect(record?.wordCount == 0)
        }
    }

    @Test("the rebuilt FTS table has a title column and is empty")
    func ftsRebuilt() async throws {
        try await withMigratedStore(seed: true) { (store: LibraryStore) async throws -> Void in
            // FTS5 tables cannot be ALTERed, so the migration drops and
            // recreates. Safe only because content re-derives from disk.
            #expect(try await store.ftsColumnCount() == 4)
            #expect(try await store.ftsRowCount() == 0)
            // Searching before the reindex finds nothing rather than failing.
            #expect(try await store.search("content").isEmpty)
        }
    }

    @Test("a fresh database is created at v2 directly")
    func freshDatabaseIsVersionTwo() async throws {
        try await withMigratedStore(seed: false) { (store: LibraryStore) async throws -> Void in
            #expect(try await store.schemaVersionOnDisk() == 2)
            #expect(try await store.ftsColumnCount() == 4)
        }
    }

    @Test("migrating an already-migrated database is a no-op")
    func migrationIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaV2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        try seedVersionOneDatabase(at: url)

        let first = try LibraryStore(databaseURL: url)
        try await first.close()

        let second = try LibraryStore(databaseURL: url)
        do {
            #expect(try await second.schemaVersionOnDisk() == 2)
            #expect(try await second.record(forRelativePath: "Notes/Kept.md")?.isFavorite == true)
            try await second.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await second.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    // MARK: - Column-index drift

    @Test("search reads the snippet from the right column after the rebuild")
    func snippetColumnIndexIsDerived() async throws {
        try await withMigratedStore(seed: false) { (store: LibraryStore) async throws -> Void in
            // Adding a title column shifts both the snippet column index and
            // the result column offset. Both were hardcoded before v2, and
            // getting either wrong still compiles while returning the wrong
            // string.
            try await add(
                store, "Note.md",
                "Fruit Notes\n\nThe body mentions kumquats exactly once."
            )
            let results = try await store.search("kumquats")
            #expect(results.count == 1)
            #expect(results.first?.record.relativePath == "Note.md")
            #expect(results.first?.snippet.contains("kumquats") == true)
        }
    }

    @Test("a title match outranks a body match")
    func titleIsWeightedAboveBody() async throws {
        try await withMigratedStore(seed: false) { (store: LibraryStore) async throws -> Void in
            // Filenames are auto-derived from titles now, so the title is the
            // strong signal and takes the heaviest bm25 weight.
            try await add(store, "a.md", "Unrelated Heading\n\nsomewhere in here is budget")
            try await add(store, "b.md", "Budget\n\nnothing else relevant")

            let results = try await store.search("budget")
            #expect(results.count == 2)
            #expect(results.first?.record.relativePath == "b.md")
        }
    }
}
