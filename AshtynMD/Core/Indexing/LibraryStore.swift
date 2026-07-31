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

    // MARK: Derived from the note body (schema v2)

    /// First line of the note, markup stripped. Empty for an untitled note.
    var title: String = ""
    /// Case-folded title, the key wiki links resolve against.
    var titleKey: String = ""
    /// Two lines of body text for the note list.
    var excerpt: String = ""
    var createdAt: Date?
    var wordCount: Int = 0
    var characterCount: Int = 0
    var todoTotal: Int = 0
    var todoOpen: Int = 0

    // MARK: App-side state

    /// Index-only, same acceptable loss class as `isFavorite`.
    var isPinned: Bool = false
    /// Cached from the note's on-disk location under `.archive`.
    var isArchived: Bool = false
    /// Cached from the note's on-disk location under `.trash`.
    var trashedAt: Date?
    /// Where a trashed note came from, so restore works without the index.
    var trashedOriginPath: String?
    /// False once the user renames the file themselves, which stops the
    /// title from overwriting their choice.
    var titleIsManaged: Bool = true
    /// Set by a migration to force the indexer to revisit the file.
    var reindexPending: Bool = false
}

/// Search hit with an FTS-generated snippet.
struct SearchResult: Identifiable, Hashable, Sendable {
    var record: FileRecord
    var snippet: String
    var id: Int64 { record.id }
}

/// Everything the indexer knows about a file in one value.
///
/// Replaces a growing positional parameter list on `upsertFile`; the old
/// signature is kept as a shim so existing callers and tests still compile.
struct FileIndexUpdate: Sendable {
    var relativePath: String
    var size: Int64
    var modifiedAt: Date
    var createdAt: Date?
    var contentHash: String?
    var languageID: LanguageID
    var resourceID: String?
    var content: String?
    /// nil for non-Markdown files, which are never parsed for tags or titles.
    var parsed: ParsedNote?

    init(
        relativePath: String,
        size: Int64,
        modifiedAt: Date,
        createdAt: Date? = nil,
        contentHash: String? = nil,
        languageID: LanguageID,
        resourceID: String? = nil,
        content: String? = nil,
        parsed: ParsedNote? = nil
    ) {
        self.relativePath = relativePath
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.contentHash = contentHash
        self.languageID = languageID
        self.resourceID = resourceID
        self.content = content
        self.parsed = parsed
    }
}

/// One node of the sidebar's nested tag tree.
struct TagNode: Identifiable, Hashable, Sendable {
    /// Case-folded full path, e.g. `work/alpha`.
    let key: String
    /// Leaf segment as written, e.g. `alpha`.
    let displayName: String
    /// Full path as written, e.g. `Work/Alpha`.
    let displayPath: String
    /// Active notes carrying this tag or any descendant, counted once each.
    let count: Int
    let isPinned: Bool
    var children: [TagNode] = []

    var id: String { key }

    /// OutlineGroup draws a chevron for any non-nil children array.
    var nonEmptyChildren: [TagNode]? {
        children.isEmpty ? nil : children
    }
}

/// Counts for the fixed sidebar rows, gathered in a single query.
struct LibraryCounts: Sendable, Equatable {
    var notes = 0
    var untagged = 0
    var todo = 0
    var pinned = 0
    var favorites = 0
    var archived = 0
    var trashed = 0
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
    static let schemaVersion = 2

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

    /// Releases SQLite resources before the library's files or security scope
    /// are torn down. Safe to call more than once.
    func close() throws {
        try database.close()
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
        if version < 2 {
            // Note-shaped metadata derived from the body, plus the app-side
            // state a Bear-like library needs. Kept as an ALTER ladder rather
            // than folded into the v1 CREATE so the path a shipped database
            // takes is exactly the path a fresh one takes.
            try database.executeScript("""
            ALTER TABLE files ADD COLUMN title TEXT NOT NULL DEFAULT '';
            ALTER TABLE files ADD COLUMN title_key TEXT NOT NULL DEFAULT '';
            ALTER TABLE files ADD COLUMN excerpt TEXT NOT NULL DEFAULT '';
            ALTER TABLE files ADD COLUMN created_at REAL;
            ALTER TABLE files ADD COLUMN word_count INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE files ADD COLUMN char_count INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE files ADD COLUMN todo_total INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE files ADD COLUMN todo_open INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE files ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE files ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE files ADD COLUMN trashed_at REAL;
            ALTER TABLE files ADD COLUMN trashed_origin_path TEXT;
            ALTER TABLE files ADD COLUMN title_is_managed INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE files ADD COLUMN reindex_pending INTEGER NOT NULL DEFAULT 0;

            CREATE INDEX IF NOT EXISTS idx_files_title_key ON files(title_key);
            CREATE INDEX IF NOT EXISTS idx_files_state
                ON files(is_archived, trashed_at, mtime DESC);
            CREATE INDEX IF NOT EXISTS idx_files_created ON files(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_files_todo ON files(todo_open) WHERE todo_open > 0;

            -- Materialized path rather than parent_id: every hot query is
            -- "this tag and its descendants", which a path makes a plain
            -- predicate. The usual weakness (renames rewrite the subtree)
            -- does not apply because tags are derived from note text, so a
            -- rename rewrites the notes and the table is re-derived.
            CREATE TABLE IF NOT EXISTS tags (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE,
                display_path TEXT NOT NULL,
                parent_path TEXT,
                depth INTEGER NOT NULL DEFAULT 0,
                is_pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_tags_parent ON tags(parent_path);

            -- Stores the exact tag *and every ancestor*, so a sidebar count is
            -- one grouped equality join with no DISTINCT and no CTE.
            CREATE TABLE IF NOT EXISTS file_tags (
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                tag_id  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                is_direct INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (file_id, tag_id)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS idx_file_tags_tag ON file_tags(tag_id, is_direct);

            -- Deliberately no target_file_id: resolution is title_key equality,
            -- so backlinks follow a renamed note with no maintenance and
            -- ambiguity is just "more than one row".
            CREATE TABLE IF NOT EXISTS links (
                source_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                location INTEGER NOT NULL,
                target_title_key TEXT NOT NULL,
                raw_target TEXT NOT NULL,
                PRIMARY KEY (source_file_id, location)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS idx_links_target ON links(target_title_key);

            -- FTS5 tables cannot be ALTERed, so adding a title column means
            -- dropping and recreating. Cheap only because content is
            -- re-derivable from disk, which reindex_pending then forces.
            DROP TABLE IF EXISTS files_fts;
            CREATE VIRTUAL TABLE files_fts USING fts5(
                title, name, relative_path, content,
                tokenize='unicode61 remove_diacritics 2'
            );

            UPDATE files SET reindex_pending = 1;
            """)
            database.userVersion = 2
        }
        // Future migrations branch on `version` here, one step at a time.
    }

    // MARK: - Introspection (tests)

    func schemaVersionOnDisk() throws -> Int {
        database.userVersion
    }

    func ftsColumnCount() throws -> Int {
        try database.query("PRAGMA table_info(files_fts)") { _ in 1 }.count
    }

    func ftsRowCount() throws -> Int {
        Int(try database.query("SELECT COUNT(*) FROM files_fts") { $0.int(0) }.first ?? 0)
    }


    // MARK: - Upserts from the indexer

    /// Compatibility overload: metadata-only upserts and existing tests.
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
        try upsertFile(
            FileIndexUpdate(
                relativePath: relativePath,
                size: size,
                modifiedAt: modifiedAt,
                contentHash: contentHash,
                languageID: languageID,
                resourceID: resourceID,
                content: content
            )
        )
    }

    /// Inserts or updates a file row, its FTS entry, and its tag and link rows.
    /// `content` is nil for files excluded from full-text indexing (binary or
    /// oversized); `parsed` is nil for anything that is not Markdown.
    @discardableResult
    func upsertFile(_ update: FileIndexUpdate) throws -> Int64 {
        let name = (update.relativePath as NSString).lastPathComponent
        let parsed = update.parsed
        // A non-Markdown file still gets a usable title so the note list and
        // wiki-link resolution have something to show.
        let title = parsed?.title ?? name
        let titleKey = parsed.map(\.titleKey) ?? MarkdownMetadata.foldTitle(name)

        var fileID: Int64 = 0
        try database.transaction {
            let existing = try database.query(
                "SELECT id FROM files WHERE relative_path = ?",
                [.text(update.relativePath)]
            ) { $0.int(0) }.first

            let metadata: [SQLiteValue] = [
                .text(title),
                .text(titleKey),
                .text(parsed?.excerpt ?? ""),
                update.createdAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .integer(Int64(parsed?.wordCount ?? 0)),
                .integer(Int64(parsed?.characterCount ?? 0)),
                .integer(Int64(parsed?.todoTotal ?? 0)),
                .integer(Int64(parsed?.todoOpen ?? 0)),
            ]

            if let existing {
                fileID = existing
                try database.run("""
                    UPDATE files SET name=?, size=?, mtime=?, content_hash=?, language=?,
                                     resource_id=?, title=?, title_key=?, excerpt=?,
                                     created_at=COALESCE(?, created_at), word_count=?,
                                     char_count=?, todo_total=?, todo_open=?,
                                     reindex_pending=0
                    WHERE id=?
                    """, [
                        .text(name), .integer(update.size),
                        .double(update.modifiedAt.timeIntervalSince1970),
                        update.contentHash.map(SQLiteValue.text) ?? .null,
                        .text(update.languageID.rawValue),
                        update.resourceID.map(SQLiteValue.text) ?? .null,
                    ] + metadata + [.integer(existing)])
            } else {
                try database.run("""
                    INSERT INTO files (relative_path, name, size, mtime, content_hash, language,
                                       resource_id, title, title_key, excerpt, created_at,
                                       word_count, char_count, todo_total, todo_open)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [
                        .text(update.relativePath), .text(name), .integer(update.size),
                        .double(update.modifiedAt.timeIntervalSince1970),
                        update.contentHash.map(SQLiteValue.text) ?? .null,
                        .text(update.languageID.rawValue),
                        update.resourceID.map(SQLiteValue.text) ?? .null,
                    ] + metadata)
                fileID = database.lastInsertRowID
            }

            try database.run("DELETE FROM files_fts WHERE rowid = ?", [.integer(fileID)])
            try database.run("""
                INSERT INTO files_fts (rowid, title, name, relative_path, content)
                VALUES (?,?,?,?,?)
                """,
                [
                    .integer(fileID), .text(title), .text(name),
                    .text(update.relativePath), .text(update.content ?? ""),
                ]
            )

            try writeTags(parsed?.tagClosure() ?? [], fileID: fileID)
            try writeLinks(parsed?.links ?? [], fileID: fileID)
        }
        return fileID
    }

    /// Delete-then-insert rather than reconciling: at 0-10 tags per note a
    /// diff saves nothing and adds a real bug surface.
    private func writeTags(_ closure: [MarkdownTag.ClosureEntry], fileID: Int64) throws {
        try database.run("DELETE FROM file_tags WHERE file_id = ?", [.integer(fileID)])
        for entry in closure {
            let parent = entry.key.contains("/")
                ? String(entry.key[entry.key.startIndex..<entry.key.lastIndex(of: "/")!])
                : nil
            try database.run("""
                INSERT INTO tags (path, display_path, parent_path, depth)
                VALUES (?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET display_path = excluded.display_path
                """, [
                    .text(entry.key), .text(entry.displayPath),
                    parent.map(SQLiteValue.text) ?? .null,
                    .integer(Int64(entry.key.split(separator: "/").count)),
                ])
            // MAX on conflict handles a note tagged both #work and #work/alpha:
            // `work` has to end up direct.
            try database.run("""
                INSERT INTO file_tags (file_id, tag_id, is_direct)
                VALUES (?, (SELECT id FROM tags WHERE path = ?), ?)
                ON CONFLICT(file_id, tag_id) DO UPDATE
                  SET is_direct = MAX(file_tags.is_direct, excluded.is_direct)
                """, [
                    .integer(fileID), .text(entry.key),
                    .integer(entry.isDirect ? 1 : 0),
                ])
        }
    }

    private func writeLinks(_ links: [ParsedNote.LinkHit], fileID: Int64) throws {
        try database.run("DELETE FROM links WHERE source_file_id = ?", [.integer(fileID)])
        for link in links {
            try database.run("""
                INSERT INTO links (source_file_id, location, target_title_key, raw_target)
                VALUES (?,?,?,?)
                ON CONFLICT(source_file_id, location) DO UPDATE
                  SET target_title_key = excluded.target_title_key,
                      raw_target = excluded.raw_target
                """, [
                    .integer(fileID), .integer(Int64(link.range.location)),
                    .text(link.key), .text(link.target),
                ])
        }
    }

    /// Drops tags no note carries any more. Pinned tags survive with zero
    /// notes on purpose: the user pinned them.
    @discardableResult
    func pruneOrphanTags() throws -> Int {
        let orphans = try database.query("""
            SELECT id FROM tags
            WHERE is_pinned = 0 AND id NOT IN (SELECT tag_id FROM file_tags)
            """) { $0.int(0) }
        guard !orphans.isEmpty else { return 0 }
        try database.transaction {
            for id in orphans {
                try database.run("DELETE FROM tags WHERE id = ?", [.integer(id)])
            }
        }
        return orphans.count
    }

    func setTagPinned(_ pinned: Bool, key: String) throws {
        try database.run(
            "UPDATE tags SET is_pinned = ? WHERE path = ?",
            [.integer(pinned ? 1 : 0), .text(key)]
        )
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

    private static let recordColumns = """
        id, relative_path, name, size, mtime, content_hash, language, resource_id, \
        is_favorite, last_opened_at, title, title_key, excerpt, created_at, word_count, \
        char_count, todo_total, todo_open, is_pinned, is_archived, trashed_at, \
        trashed_origin_path, title_is_managed, reindex_pending
        """

    /// Derived, never hardcoded: `search` reads its snippet from the column
    /// right after the record columns, and that offset shifted silently when
    /// v2 widened the row.
    private static let recordColumnCount = recordColumns
        .split(separator: ",")
        .count

    /// The record columns qualified with a table alias, for joins.
    private static func recordColumns(prefixedWith alias: String) -> String {
        recordColumns
            .split(separator: ",")
            .map { "\(alias).\($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: ", ")
    }

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
            lastOpenedAt: row.optionalDouble(9).map(Date.init(timeIntervalSince1970:)),
            title: row.text(10),
            titleKey: row.text(11),
            excerpt: row.text(12),
            createdAt: row.optionalDouble(13).map(Date.init(timeIntervalSince1970:)),
            wordCount: Int(row.int(14)),
            characterCount: Int(row.int(15)),
            todoTotal: Int(row.int(16)),
            todoOpen: Int(row.int(17)),
            isPinned: row.int(18) != 0,
            isArchived: row.int(19) != 0,
            trashedAt: row.optionalDouble(20).map(Date.init(timeIntervalSince1970:)),
            trashedOriginPath: row.optionalText(21),
            titleIsManaged: row.int(22) != 0,
            reindexPending: row.int(23) != 0
        )
    }

    /// Raw values are interpolated into SQL, so this stays an enum — never a
    /// free string — and pinned-first is prepended rather than embedded.
    enum SortOrder: String, Sendable, CaseIterable {
        case modifiedDescending = "mtime DESC"
        case nameAscending = "name COLLATE NOCASE ASC"
        /// Backed by a real creation date since v2, not the `id DESC` proxy.
        case createdDescending = "COALESCE(created_at, mtime) DESC"
        case titleAscending = "title COLLATE NOCASE ASC, name COLLATE NOCASE ASC"
    }

    /// Pinned notes float to the top of every ordering.
    private static func orderClause(_ order: SortOrder) -> String {
        "is_pinned DESC, \(order.rawValue)"
    }

    /// Notes that are neither archived nor trashed.
    private static let activePredicate = "is_archived = 0 AND trashed_at IS NULL"

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

    func setPinned(_ pinned: Bool, relativePath: String) throws {
        try database.run(
            "UPDATE files SET is_pinned = ? WHERE relative_path = ?",
            [.integer(pinned ? 1 : 0), .text(relativePath)]
        )
    }

    func setTitleIsManaged(_ managed: Bool, relativePath: String) throws {
        try database.run(
            "UPDATE files SET title_is_managed = ? WHERE relative_path = ?",
            [.integer(managed ? 1 : 0), .text(relativePath)]
        )
    }

    // MARK: - Note lists

    /// Active notes: not archived, not trashed.
    func notes(sortedBy order: SortOrder = .modifiedDescending) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE \(Self.activePredicate)
            ORDER BY \(Self.orderClause(order))
            """,
            transform: Self.makeRecord
        )
    }

    /// Active notes carrying no tag of their own.
    func untaggedNotes(sortedBy order: SortOrder = .modifiedDescending) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE \(Self.activePredicate)
              AND NOT EXISTS (
                SELECT 1 FROM file_tags ft WHERE ft.file_id = files.id AND ft.is_direct = 1
              )
            ORDER BY \(Self.orderClause(order))
            """,
            transform: Self.makeRecord
        )
    }

    func todoNotes(sortedBy order: SortOrder = .modifiedDescending) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE \(Self.activePredicate) AND todo_open > 0
            ORDER BY \(Self.orderClause(order))
            """,
            transform: Self.makeRecord
        )
    }

    func pinnedNotes(sortedBy order: SortOrder = .modifiedDescending) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE \(Self.activePredicate) AND is_pinned = 1
            ORDER BY \(Self.orderClause(order))
            """,
            transform: Self.makeRecord
        )
    }

    func archivedNotes(sortedBy order: SortOrder = .modifiedDescending) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE is_archived = 1 AND trashed_at IS NULL
            ORDER BY \(Self.orderClause(order))
            """,
            transform: Self.makeRecord
        )
    }

    func trashedNotes(sortedBy order: SortOrder = .modifiedDescending) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE trashed_at IS NOT NULL
            ORDER BY trashed_at DESC
            """,
            transform: Self.makeRecord
        )
    }

    /// Active notes tagged `key` or any descendant of it.
    ///
    /// A plain equality join, because `file_tags` stores every ancestor.
    func notes(
        taggedWith key: String,
        sortedBy order: SortOrder = .modifiedDescending
    ) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns(prefixedWith: "f")) FROM files f
            JOIN file_tags ft ON ft.file_id = f.id
            JOIN tags t ON t.id = ft.tag_id
            WHERE t.path = ? AND f.is_archived = 0 AND f.trashed_at IS NULL
            ORDER BY f.\(Self.orderClause(order).replacingOccurrences(of: ", ", with: ", f."))
            """,
            [.text(key)],
            transform: Self.makeRecord
        )
    }

    // MARK: - Tags

    /// The nested tag tree with per-tag counts.
    ///
    /// One grouped query: the count already includes descendants because the
    /// closure rows put every note under every ancestor exactly once.
    func tagTree() throws -> [TagNode] {
        struct Row {
            let key: String
            let displayPath: String
            let parentPath: String?
            let count: Int
            let isPinned: Bool
        }
        let rows = try database.query("""
            SELECT t.path, t.display_path, t.parent_path, t.is_pinned, COUNT(f.id)
            FROM tags t
            LEFT JOIN file_tags ft ON ft.tag_id = t.id
            LEFT JOIN files f ON f.id = ft.file_id
                 AND f.trashed_at IS NULL AND f.is_archived = 0
            GROUP BY t.id
            ORDER BY t.path
            """) { row in
            Row(
                key: row.text(0),
                displayPath: row.text(1),
                parentPath: row.optionalText(2),
                count: Int(row.int(4)),
                isPinned: row.int(3) != 0
            )
        }

        var childrenByParent: [String: [Row]] = [:]
        var roots: [Row] = []
        for row in rows {
            if let parent = row.parentPath, rows.contains(where: { $0.key == parent }) {
                childrenByParent[parent, default: []].append(row)
            } else {
                roots.append(row)
            }
        }

        func build(_ row: Row) -> TagNode {
            let leaf = row.displayPath.split(separator: "/").last.map(String.init)
                ?? row.displayPath
            let children = (childrenByParent[row.key] ?? [])
                .sorted { $0.key < $1.key }
                .map(build)
            return TagNode(
                key: row.key,
                displayName: leaf,
                displayPath: row.displayPath,
                count: row.count,
                isPinned: row.isPinned,
                children: children
            )
        }
        return roots.sorted { $0.key < $1.key }.map(build)
    }

    /// Every fixed sidebar row's count, in one scan of `files`.
    func counts() throws -> LibraryCounts {
        try database.query("""
            SELECT
              SUM(active),
              SUM(active AND untagged),
              SUM(active AND has_todo),
              SUM(active AND pinned),
              SUM(active AND fav),
              SUM(archived),
              SUM(trashed)
            FROM (
              SELECT
                (is_archived = 0 AND trashed_at IS NULL)          AS active,
                (todo_open > 0)                                   AS has_todo,
                is_pinned                                         AS pinned,
                is_favorite                                       AS fav,
                (is_archived = 1 AND trashed_at IS NULL)          AS archived,
                (trashed_at IS NOT NULL)                          AS trashed,
                NOT EXISTS (
                  SELECT 1 FROM file_tags ft
                  WHERE ft.file_id = files.id AND ft.is_direct = 1
                )                                                 AS untagged
              FROM files
            )
            """) { row in
            LibraryCounts(
                notes: Int(row.int(0)),
                untagged: Int(row.int(1)),
                todo: Int(row.int(2)),
                pinned: Int(row.int(3)),
                favorites: Int(row.int(4)),
                archived: Int(row.int(5)),
                trashed: Int(row.int(6))
            )
        }.first ?? LibraryCounts()
    }

    /// Candidate paths for a tag rename or delete, free thanks to the closure.
    func filesTagged(withKeyOrDescendant key: String) throws -> [String] {
        try database.query("""
            SELECT DISTINCT f.relative_path FROM files f
            JOIN file_tags ft ON ft.file_id = f.id
            JOIN tags t ON t.id = ft.tag_id
            WHERE t.path = ? AND f.trashed_at IS NULL
            """,
            [.text(key)]
        ) { $0.text(0) }
    }

    // MARK: - Wiki links

    /// Notes whose title matches `key`. Empty means unresolved, more than one
    /// means ambiguous.
    func resolveWikiLink(_ key: String) throws -> [FileRecord] {
        try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE title_key = ? AND trashed_at IS NULL
            ORDER BY mtime DESC
            """,
            [.text(key)],
            transform: Self.makeRecord
        )
    }

    func backlinks(toTitleKey key: String, excluding fileID: Int64) throws -> [FileRecord] {
        try database.query("""
            SELECT DISTINCT \(Self.recordColumns(prefixedWith: "f")) FROM links l
            JOIN files f ON f.id = l.source_file_id
            WHERE l.target_title_key = ? AND f.trashed_at IS NULL AND f.id != ?
            ORDER BY f.mtime DESC
            """,
            [.text(key), .integer(fileID)],
            transform: Self.makeRecord
        )
    }

    func outgoingLinks(fromFileID fileID: Int64) throws -> [(raw: String, key: String)] {
        try database.query("""
            SELECT raw_target, target_title_key FROM links
            WHERE source_file_id = ? ORDER BY location
            """,
            [.integer(fileID)]
        ) { (raw: $0.text(0), key: $0.text(1)) }
    }

    /// Title matches for the wiki-link completion popover.
    func titleSuggestions(prefix: String, limit: Int = 20) throws -> [FileRecord] {
        let folded = MarkdownMetadata.foldTitle(prefix)
        guard !folded.isEmpty else { return [] }
        return try database.query("""
            SELECT \(Self.recordColumns) FROM files
            WHERE title_key LIKE ? AND trashed_at IS NULL AND title != ''
            ORDER BY mtime DESC LIMIT ?
            """,
            [.text(folded + "%"), .integer(Int64(limit))],
            transform: Self.makeRecord
        )
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

        // Column 3 is `content` in the v2 FTS shape (title, name,
        // relative_path, content), and the snippet lands immediately after the
        // record columns. Both indices are derived rather than written out:
        // hardcoding either still compiles and silently returns wrong strings.
        return try database.query("""
            SELECT \(Self.recordColumns(prefixedWith: "f")),
                   snippet(files_fts, 3, '⟦', '⟧', '…', 12)
            FROM files_fts
            JOIN files f ON f.id = files_fts.rowid
            WHERE files_fts MATCH ?
            ORDER BY bm25(files_fts, 10.0, 6.0, 3.0, 1.0)
            LIMIT ?
            """,
            [.text(ftsQuery), .integer(Int64(limit))]
        ) { row in
            SearchResult(
                record: Self.makeRecord(row),
                snippet: row.text(Self.recordColumnCount)
            )
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
