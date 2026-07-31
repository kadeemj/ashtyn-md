import Foundation
import Testing

@testable import AshtynMD

@Suite("SQLite statement cache")
struct SQLiteDatabaseTests {
    /// Builds a database in a fresh temporary directory and hands back a
    /// teardown closure. Callers must close the database before removing the
    /// directory, matching the convention in LibraryStoreTests.
    private func makeDatabase() throws -> (SQLiteDatabase, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        try database.executeScript(
            "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL);"
        )
        return (database, {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        })
    }

    @Test("repeated identical statements are prepared once")
    func repeatedStatementsPrepareOnce() throws {
        let (database, teardown) = try makeDatabase()
        defer { teardown() }

        let before = database.statementPrepareCount
        for index in 0..<5 {
            try database.run(
                "INSERT INTO items (name, score) VALUES (?, ?)",
                [.text("row-\(index)"), .double(Double(index))]
            )
        }
        #expect(database.statementPrepareCount - before == 1)

        let names = try database.query("SELECT name FROM items ORDER BY id") { $0.text(0) }
        #expect(names == ["row-0", "row-1", "row-2", "row-3", "row-4"])
    }

    @Test("distinct SQL gets distinct cache entries")
    func distinctSQLCachesSeparately() throws {
        let (database, teardown) = try makeDatabase()
        defer { teardown() }

        let before = database.statementPrepareCount
        try database.run("INSERT INTO items (name) VALUES (?)", [.text("a")])
        try database.run("INSERT INTO items (name, score) VALUES (?, ?)", [.text("b"), .double(1)])
        try database.run("INSERT INTO items (name) VALUES (?)", [.text("c")])
        #expect(database.statementPrepareCount - before == 2)
        #expect(database.cachedStatementCount == 2)
    }

    @Test("reused statements clear stale bindings")
    func reuseClearsBindings() throws {
        let (database, teardown) = try makeDatabase()
        defer { teardown() }

        try database.run("INSERT INTO items (name, score) VALUES (?, ?)", [.text("a"), .double(2.5)])
        // Same SQL, but the second parameter is explicitly null. If bindings
        // were not cleared, the cached 2.5 would survive.
        try database.run("INSERT INTO items (name, score) VALUES (?, ?)", [.text("b"), .null])

        let scores = try database.query("SELECT score FROM items ORDER BY id") { $0.optionalDouble(0) }
        #expect(scores == [2.5, nil])
    }

    @Test("a partially consumed query does not leak rows into the next run")
    func partiallyConsumedQueryResets() throws {
        let (database, teardown) = try makeDatabase()
        defer { teardown() }

        for index in 0..<4 {
            try database.run("INSERT INTO items (name) VALUES (?)", [.text("row-\(index)")])
        }
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            _ = try database.query("SELECT name FROM items ORDER BY id") { row -> String in
                if row.text(0) == "row-1" { throw Stop() }
                return row.text(0)
            }
        }
        // The aborted statement must be reset before it is handed out again.
        let names = try database.query("SELECT name FROM items ORDER BY id") { $0.text(0) }
        #expect(names == ["row-0", "row-1", "row-2", "row-3"])
    }

    @Test("nested identical queries do not share one statement")
    func nestedIdenticalQueriesAreIsolated() throws {
        let (database, teardown) = try makeDatabase()
        defer { teardown() }

        for index in 0..<3 {
            try database.run("INSERT INTO items (name) VALUES (?)", [.text("row-\(index)")])
        }
        let sql = "SELECT name FROM items ORDER BY id"
        var inner: [String] = []
        let outer = try database.query(sql) { row -> String in
            if inner.isEmpty {
                inner = try database.query(sql) { $0.text(0) }
            }
            return row.text(0)
        }
        #expect(outer == ["row-0", "row-1", "row-2"])
        #expect(inner == ["row-0", "row-1", "row-2"])
    }

    @Test("schema changes drop cached statements")
    func schemaChangeInvalidatesCache() throws {
        let (database, teardown) = try makeDatabase()
        defer { teardown() }

        try database.run("INSERT INTO items (name) VALUES (?)", [.text("a")])
        #expect(database.cachedStatementCount > 0)

        try database.executeScript("DROP TABLE items; CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);")
        #expect(database.cachedStatementCount == 0)

        try database.run("INSERT INTO items (name) VALUES (?)", [.text("b")])
        let names = try database.query("SELECT name FROM items ORDER BY id") { $0.text(0) }
        #expect(names == ["b"])
    }

    @Test("transaction control does not flush the cache")
    func transactionControlKeepsCache() throws {
        let (database, teardown) = try makeDatabase()
        defer { teardown() }

        try database.run("INSERT INTO items (name) VALUES (?)", [.text("a")])
        let cached = database.cachedStatementCount
        #expect(cached > 0)

        try database.transaction {
            try database.run("INSERT INTO items (name) VALUES (?)", [.text("b")])
        }
        // BEGIN/COMMIT must not evict prepared statements — otherwise every
        // indexer transaction would re-prepare everything it uses.
        #expect(database.cachedStatementCount == cached)
        #expect(try database.query("SELECT COUNT(*) FROM items") { $0.int(0) }.first == 2)
    }

    @Test("the cache is bounded")
    func cacheIsBounded() throws {
        let (database, teardown) = try makeDatabase()
        defer { teardown() }

        for index in 0..<(SQLiteDatabase.statementCacheCapacity + 10) {
            // Distinct SQL text on every iteration.
            _ = try database.query("SELECT \(index), name FROM items") { $0.int(0) }
        }
        #expect(database.cachedStatementCount <= SQLiteDatabase.statementCacheCapacity)
    }

    @Test("closing finalizes cached statements")
    func closeFinalizesCache() throws {
        let (database, teardown) = try makeDatabase()
        defer { teardown() }

        try database.run("INSERT INTO items (name) VALUES (?)", [.text("a")])
        #expect(database.cachedStatementCount > 0)
        try database.close()
        #expect(database.cachedStatementCount == 0)
        #expect(throws: SQLiteError.self) {
            try database.run("INSERT INTO items (name) VALUES (?)", [.text("b")])
        }
    }
}
