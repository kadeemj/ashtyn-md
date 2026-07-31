import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, LocalizedError {
    case closed
    case openFailed(String)
    case prepareFailed(String, sql: String)
    case stepFailed(String, sql: String)
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "Database is closed."
        case .openFailed(let message): return "Couldn’t open database: \(message)"
        case .prepareFailed(let message, let sql): return "Bad statement (\(message)): \(sql)"
        case .stepFailed(let message, let sql): return "Statement failed (\(message)): \(sql)"
        case .bindFailed(let message): return "Bad parameter: \(message)"
        }
    }
}

/// Values bindable to a statement parameter.
enum SQLiteValue: Sendable {
    case text(String)
    case integer(Int64)
    case double(Double)
    case null
}

/// Minimal SQLite3 wrapper. Not thread-safe by itself — always owned by a
/// single actor (LibraryStore).
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Compiled statements, keyed by SQL text. Preparing is the dominant cost
    /// of the indexer's per-file work, so statements are reused across calls
    /// and only recompiled when the schema changes.
    private var statementCache: [String: OpaquePointer] = [:]
    /// Insertion/most-recent-use order for `statementCache`, oldest first.
    private var statementOrder: [String] = []
    /// SQL currently being stepped. A reentrant call with the same text gets a
    /// fresh uncached statement instead of corrupting the in-flight cursor.
    private var statementsInUse: Set<String> = []

    static let statementCacheCapacity = 64

    /// Total number of `sqlite3_prepare_v2` calls. Test observability.
    private(set) var statementPrepareCount = 0

    var cachedStatementCount: Int { statementCache.count }

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError.openFailed(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }

    deinit {
        try? close()
    }

    /// Closes the connection. Safe to call more than once.
    func close() throws {
        guard let handle else { return }
        flushStatementCache()
        let result = sqlite3_close_v2(handle)
        guard result == SQLITE_OK else {
            throw SQLiteError.stepFailed(
                String(cString: sqlite3_errmsg(handle)),
                sql: "CLOSE"
            )
        }
        self.handle = nil
    }

    private var lastMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    private func openHandle() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError.closed }
        return handle
    }

    /// Runs one or more semicolon-separated statements with no parameters.
    ///
    /// Anything that is not plain transaction control is assumed to be able to
    /// change the schema, so the statement cache is flushed first. BEGIN,
    /// COMMIT, and ROLLBACK are exempt — they run around every indexer write
    /// and flushing there would defeat the cache entirely.
    func executeScript(_ sql: String) throws {
        let handle = try openHandle()
        if !Self.isTransactionControl(sql) {
            flushStatementCache()
        }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.stepFailed(lastMessage, sql: sql)
        }
    }

    /// Runs a single statement with positional `?` parameters.
    func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        let lease = try prepare(sql, parameters)
        defer { release(lease) }
        let result = sqlite3_step(lease.statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.stepFailed(lastMessage, sql: sql)
        }
    }

    /// Runs a query and maps each row through `transform`.
    func query<T>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        transform: (SQLiteRow) throws -> T
    ) throws -> [T] {
        let lease = try prepare(sql, parameters)
        defer { release(lease) }
        var results: [T] = []
        while true {
            let result = sqlite3_step(lease.statement)
            if result == SQLITE_ROW {
                results.append(try transform(SQLiteRow(statement: lease.statement)))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.stepFailed(lastMessage, sql: sql)
            }
        }
        return results
    }

    private static func isTransactionControl(_ sql: String) -> Bool {
        let head = sql
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        for keyword in ["BEGIN", "COMMIT", "ROLLBACK", "END", "SAVEPOINT", "RELEASE"]
        where head.hasPrefix(keyword) {
            return true
        }
        return false
    }

    private func flushStatementCache() {
        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        statementCache.removeAll()
        statementOrder.removeAll()
    }

    var lastInsertRowID: Int64 {
        guard let handle else {
            preconditionFailure("Database is closed.")
        }
        return sqlite3_last_insert_rowid(handle)
    }

    var userVersion: Int {
        get {
            (try? query("PRAGMA user_version") { $0.int(0) })?.first.map(Int.init) ?? 0
        }
        set {
            try? executeScript("PRAGMA user_version = \(newValue)")
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try executeScript("BEGIN IMMEDIATE")
        do {
            try body()
            try executeScript("COMMIT")
        } catch {
            try? executeScript("ROLLBACK")
            throw error
        }
    }

    /// A borrowed statement. Cached leases go back to the pool on release;
    /// uncached ones (reentrant calls) are finalized instead.
    private struct StatementLease {
        let sql: String
        let statement: OpaquePointer
        let isCached: Bool
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> StatementLease {
        let handle = try openHandle()
        var statement: OpaquePointer?
        var isCached = false

        if !statementsInUse.contains(sql), let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            statement = cached
            isCached = true
            touch(sql)
        } else {
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  statement != nil else {
                if let statement { sqlite3_finalize(statement) }
                throw SQLiteError.prepareFailed(lastMessage, sql: sql)
            }
            statementPrepareCount += 1
            // Only the first compilation of a given SQL text enters the cache;
            // a reentrant duplicate stays private to its call.
            if !statementsInUse.contains(sql) && statementCache[sql] == nil {
                statementCache[sql] = statement
                statementOrder.append(sql)
                isCached = true
                evictIfNeeded()
            }
        }

        guard let statement else { throw SQLiteError.prepareFailed(lastMessage, sql: sql) }

        for (index, value) in parameters.enumerated() {
            let slot = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let string):
                result = sqlite3_bind_text(statement, slot, string, -1, SQLITE_TRANSIENT)
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, slot, integer)
            case .double(let double):
                result = sqlite3_bind_double(statement, slot, double)
            case .null:
                result = sqlite3_bind_null(statement, slot)
            }
            guard result == SQLITE_OK else {
                let lease = StatementLease(sql: sql, statement: statement, isCached: isCached)
                release(lease)
                throw SQLiteError.bindFailed(lastMessage)
            }
        }

        if isCached { statementsInUse.insert(sql) }
        return StatementLease(sql: sql, statement: statement, isCached: isCached)
    }

    /// Returns a statement to the pool. Resetting here (rather than lazily on
    /// the next `prepare`) releases any read locks the statement still holds
    /// and stops an aborted iteration from resuming mid-cursor.
    private func release(_ lease: StatementLease) {
        if lease.isCached {
            sqlite3_reset(lease.statement)
            sqlite3_clear_bindings(lease.statement)
            statementsInUse.remove(lease.sql)
        } else {
            sqlite3_finalize(lease.statement)
        }
    }

    private func touch(_ sql: String) {
        if let index = statementOrder.firstIndex(of: sql) {
            statementOrder.remove(at: index)
        }
        statementOrder.append(sql)
    }

    private func evictIfNeeded() {
        while statementCache.count > Self.statementCacheCapacity {
            // Never evict a statement that is mid-iteration.
            guard let victim = statementOrder.first(where: { !statementsInUse.contains($0) }) else {
                return
            }
            if let statement = statementCache.removeValue(forKey: victim) {
                sqlite3_finalize(statement)
            }
            if let index = statementOrder.firstIndex(of: victim) {
                statementOrder.remove(at: index)
            }
        }
    }
}

/// One row of a result set; column access by position.
struct SQLiteRow {
    let statement: OpaquePointer

    func int(_ column: Int) -> Int64 {
        sqlite3_column_int64(statement, Int32(column))
    }

    func double(_ column: Int) -> Double {
        sqlite3_column_double(statement, Int32(column))
    }

    func text(_ column: Int) -> String {
        guard let cString = sqlite3_column_text(statement, Int32(column)) else { return "" }
        return String(cString: cString)
    }

    func optionalText(_ column: Int) -> String? {
        guard sqlite3_column_type(statement, Int32(column)) != SQLITE_NULL else { return nil }
        return text(column)
    }

    func optionalDouble(_ column: Int) -> Double? {
        guard sqlite3_column_type(statement, Int32(column)) != SQLITE_NULL else { return nil }
        return double(column)
    }
}
