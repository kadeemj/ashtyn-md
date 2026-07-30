import Foundation

/// One indexed file, mirrored from disk. Paths are relative to the library
/// root; no note body is stored outside the FTS index.
struct FileRecord: Identifiable, Hashable, Sendable {
    var id: Int64
    var relativePath: String
    var name: String
    var size: Int64
    var modifiedAt: Date
    var contentHash: String?
    var languageID: LanguageID
    var resourceID: String?
    var isFavorite: Bool
    var lastOpenedAt: Date?
}

/// Search hit with an FTS-generated snippet.
struct SearchResult: Identifiable, Hashable, Sendable {
    var record: FileRecord
    var snippet: String
    var id: Int64 { record.id }
}

/// Remembered editor state for one file.
struct FileViewState: Codable, Sendable, Equatable {
    var cursorLocation: Int = 0
    var selectionLength: Int = 0
    var scrollOffset: Double = 0
    var previewScrollOffset: Double = 0
    var previewMode: String?
}

/// SQLite/FTS5-backed metadata and search store for one library. The database
/// is disposable: deleting it only loses app-side metadata, never notes.
actor LibraryStore {
    static let schemaVersion = 1

    private let database: SQLiteDatabase

    init(databaseURL: URL) throws {
        try AppSupportPaths.ensureExists(databaseURL.deletingLastPathComponent())
        let database = try SQLiteDatabase(path: databaseURL.path)
        try Self.migrate(database)
        self.database = database
    }

    /// Store for the library rooted at `root`, in its Application Support slot.
    static func forLibrary(root: URL) throws -> LibraryStore {
        let directory = AppSupportPaths.libraryDirectory(forRoot: root)
        return try LibraryStore(databaseURL: directory.appendingPathComponent("library.sqlite"))
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.executeScript("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        let version = database.userVersion
        if version < 1 {
            try database.executeScript("""
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
            """)
            database.userVersion = 1
        }
        // Future migrations branch on `version` here, one step at a time.
    }

    // MARK: - Upserts from the indexer

    /// Inserts or updates a file row and its FTS entry. `content` is nil for
    /// files excluded from full-text indexing (binary or oversized).
    @discardableResult
    func upsertFile(
        relativePath: String,
        size: Int64,
        modifiedAt: Date,
        contentHash: String?,
        languageID: LanguageID,
        resourceID: String?,
        content: String?
    ) throws -> Int64 {
        let name = (relativePath as NSString).lastPathComponent
        var fileID: Int64 = 0
        try database.transaction {
            let existing = try database.query(
                "SELECT id FROM files WHERE relative_path = ?",
                [.text(relativePath)]
            ) { $0.int(0) }.first

            if let existing {
                fileID = existing
                try database.run("""
                    UPDATE files SET name=?, size=?, mtime=?, content_hash=?, language=?, resource_id=?
                    WHERE id=?
                    """, [
                        .text(name), .integer(size),
                        .double(modifiedAt.timeIntervalSince1970),
                        contentHash.map(SQLiteValue.text) ?? .null,
                        .text(languageID.rawValue),
                        resourceID.map(SQLiteValue.text) ?? .null,
                        .integer(existing),
                    ])
            } else {
                try database.run("""
                    INSERT INTO files (relative_path, name, size, mtime, content_hash, language, resource_id)
                    VALUES (?,?,?,?,?,?,?)
                    """, [
                        .text(relativePath), .text(name), .integer(size),
                        .double(modifiedAt.timeIntervalSince1970),
                        contentHash.map(SQLiteValue.text) ?? .null,
                        .text(languageID.rawValue),
                        resourceID.map(SQLiteValue.text) ?? .null,
                    ])
                fileID = database.lastInsertRowID
            }

            try database.run("DELETE FROM files_fts WHERE rowid = ?", [.integer(fileID)])
            try database.run(
                "INSERT INTO files_fts (rowid, name, relative_path, content) VALUES (?,?,?,?)",
                [.integer(fileID), .text(name), .text(relativePath), .text(content ?? "")]
            )
        }
        return fileID
    }

    func removeFile(relativePath: String) throws {
        try database.transaction {
            let ids = try database.query(
                "SELECT id FROM files WHERE relative_path = ?", [.text(relativePath)]
            ) { $0.int(0) }
            for id in ids {
                try database.run("DELETE FROM files_fts WHERE rowid = ?", [.integer(id)])
                try database.run("DELETE FROM files WHERE id = ?", [.integer(id)])
            }
        }
    }

    /// Removes every indexed file whose path is `folderPath` or inside it.
    func removeSubtree(folderPath: String) throws {
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        try database.transaction {
            let ids = try database.query(
                "SELECT id FROM files WHERE relative_path = ? OR relative_path LIKE ?",
                [.text(folderPath), .text(prefix + "%")]
            ) { $0.int(0) }
            for id in ids {
                try database.run("DELETE FROM files_fts WHERE rowid = ?", [.integer(id)])
                try database.run("DELETE FROM files WHERE id = ?", [.integer(id)])
            }
        }
    }

    /// Rename/move detected via resource identifier: keeps id, favorites,
    /// recents, and view state attached to the file.
    func updatePath(ofFileWithResourceID resourceID: String, to relativePath: String) throws {
        let name = (relativePath as NSString).lastPathComponent
        try database.transaction {
            let ids = try database.query(
                "SELECT id FROM files WHERE resource_id = ?", [.text(resourceID)]
            ) { $0.int(0) }
            guard let id = ids.first else { return }
            try database.run(
                "UPDATE files SET relative_path = ?, name = ? WHERE id = ?",
                [.text(relativePath), .text(name), .integer(id)]
            )
            try database.run(
                "UPDATE files_fts SET name = ?, relative_path = ? WHERE rowid = ?",
                [.text(name), .text(relativePath), .integer(id)]
            )
        }
    }

    func record(forResourceID resourceID: String) throws -> FileRecord? {
        try database.query(
            "SELECT \(Self.recordColumns) FROM files WHERE resource_id = ?",
            [.text(resourceID)],
            transform: Self.makeRecord
        ).first
    }

    /// Prunes rows whose relative paths are no longer present on disk.
    /// `presentPaths` is the complete set from a full scan.
    func removeFilesNotIn(_ presentPaths: Set<String>) throws {
        let all = try database.query("SELECT id, relative_path FROM files") {
            (id: $0.int(0), path: $0.text(1))
        }
        try database.transaction {
            for row in all where !presentPaths.contains(row.path) {
                try database.run("DELETE FROM files_fts WHERE rowid = ?", [.integer(row.id)])
                try database.run("DELETE FROM files WHERE id = ?", [.integer(row.id)])
            }
        }
    }

    // MARK: - Queries

    private static let recordColumns =
        "id, relative_path, name, size, mtime, content_hash, language, resource_id, is_favorite, last_opened_at"

    private static func makeRecord(_ row: SQLiteRow) -> FileRecord {
        FileRecord(
            id: row.int(0),
            relativePath: row.text(1),
            name: row.text(2),
            size: row.int(3),
            modifiedAt: Date(timeIntervalSince1970: row.double(4)),
            contentHash: row.optionalText(5),
            languageID: LanguageID(rawValue: row.text(6)) ?? .plainText,
            resourceID: row.optionalText(7),
            isFavorite: row.int(8) != 0,
            lastOpenedAt: row.optionalDouble(9).map(Date.init(timeIntervalSince1970:))
        )
    }

    enum SortOrder: String, Sendable {
        case modifiedDescending = "mtime DESC"
        case nameAscending = "name COLLATE NOCASE ASC"
        case createdDescending = "id DESC"
    }

    func record(forRelativePath path: String) throws -> FileRecord? {
        try database.query(
            "SELECT \(Self.recordColumns) FROM files WHERE relative_path = ?",
            [.text(path)],
            transform: Self.makeRecord
        ).first
    }

    func allFiles(sortedBy order: SortOrder = .modifiedDescending) throws -> [FileRecord] {
        try database.query(
            "SELECT \(Self.recordColumns) FROM files ORDER BY \(order.rawValue)",
            transform: Self.makeRecord
        )
    }

    /// Files directly inside `folderPath` ("" = library root).
    func files(
        inFolder folderPath: String,
        sortedBy order: SortOrder = .modifiedDescending
    ) throws -> [FileRecord] {
        let prefix = folderPath.isEmpty ? "" : folderPath + "/"
        return try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE relative_path LIKE ? AND relative_path NOT LIKE ?
            ORDER BY \(order.rawValue)
            """,
            [.text(prefix + "%"), .text(prefix + "%/%")],
            transform: Self.makeRecord
        )
    }

    func favorites() throws -> [FileRecord] {
        try database.query(
            "SELECT \(Self.recordColumns) FROM files WHERE is_favorite = 1 ORDER BY name COLLATE NOCASE",
            transform: Self.makeRecord
        )
    }

    func recents(limit: Int = 30) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE last_opened_at IS NOT NULL
            ORDER BY last_opened_at DESC LIMIT ?
            """,
            [.integer(Int64(limit))],
            transform: Self.makeRecord
        )
    }

    func setFavorite(_ favorite: Bool, relativePath: String) throws {
        try database.run(
            "UPDATE files SET is_favorite = ? WHERE relative_path = ?",
            [.integer(favorite ? 1 : 0), .text(relativePath)]
        )
    }

    func markOpened(relativePath: String, at date: Date = Date()) throws {
        try database.run(
            "UPDATE files SET last_opened_at = ? WHERE relative_path = ?",
            [.double(date.timeIntervalSince1970), .text(relativePath)]
        )
    }

    func fileCount() throws -> Int {
        Int(try database.query("SELECT COUNT(*) FROM files") { $0.int(0) }.first ?? 0)
    }

    // MARK: - Search

    /// Full-text search over titles, relative paths, and content.
    func search(_ rawQuery: String, limit: Int = 100) throws -> [SearchResult] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Quote each term to keep FTS5 operators from leaking in, then use
        // prefix matching on the final term for search-as-you-type.
        let terms = trimmed.split(separator: " ").map { term in
            "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        var ftsQuery = terms.joined(separator: " ")
        ftsQuery += "*"

        return try database.query("""
            SELECT \(Self.recordColumns.split(separator: ",").map { "f.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")),
                   snippet(files_fts, 2, '⟦', '⟧', '…', 12)
            FROM files_fts
            JOIN files f ON f.id = files_fts.rowid
            WHERE files_fts MATCH ?
            ORDER BY bm25(files_fts, 8.0, 4.0, 1.0)
            LIMIT ?
            """,
            [.text(ftsQuery), .integer(Int64(limit))]
        ) { row in
            SearchResult(record: Self.makeRecord(row), snippet: row.text(10))
        }
    }

    // MARK: - View and app state

    func viewState(forFileID fileID: Int64) throws -> FileViewState? {
        let rows = try database.query(
            "SELECT state_json FROM view_state WHERE file_id = ?",
            [.integer(fileID)]
        ) { $0.text(0) }
        guard let json = rows.first, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FileViewState.self, from: data)
    }

    func saveViewState(_ state: FileViewState, forFileID fileID: Int64) throws {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        try database.run(
            "INSERT INTO view_state (file_id, state_json) VALUES (?,?) " +
            "ON CONFLICT(file_id) DO UPDATE SET state_json = excluded.state_json",
            [.integer(fileID), .text(json)]
        )
    }

    func appState(forKey key: String) throws -> String? {
        try database.query(
            "SELECT value FROM app_state WHERE key = ?", [.text(key)]
        ) { $0.text(0) }.first
    }

    func setAppState(_ value: String, forKey key: String) throws {
        try database.run(
            "INSERT INTO app_state (key, value) VALUES (?,?) " +
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }
}
