import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Durable event storage on the system SQLite (zero external
/// dependencies by design - an SDK must not impose GRDB or any other
/// package on the host app; the trade-off is this thin C-API wrapper).
///
/// Events survive crashes and offline periods here until a flush
/// succeeds. `event_id` is UNIQUE so a crash between enqueue and flush
/// cannot double-store, complementing the backend's own dedup.
final class SQLiteEventStore {
    struct StoredEvent {
        let rowId: Int64
        let payload: Data
    }

    private var db: OpaquePointer?
    private let lock = NSLock()

    init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw SQLiteError.openFailed(path)
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE,
                payload BLOB NOT NULL,
                byte_size INTEGER NOT NULL,
                created_at REAL NOT NULL
            );
            """
        )
    }

    deinit {
        sqlite3_close(db)
    }

    /// Inserts an event; returns false when event_id already exists.
    @discardableResult
    func insert(eventId: String, payload: Data) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let sql = "INSERT OR IGNORE INTO events (event_id, payload, byte_size, created_at) VALUES (?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message())
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, eventId, -1, SQLITE_TRANSIENT)
        payload.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(statement, 3, Int64(payload.count))
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(message())
        }
        return sqlite3_changes(db) > 0
    }

    /// Oldest events first, up to `limit`.
    func oldest(limit: Int) throws -> [StoredEvent] {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT id, payload FROM events ORDER BY id ASC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message())
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var results: [StoredEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(statement, 0)
            let size = Int(sqlite3_column_bytes(statement, 1))
            let payload: Data
            if let blob = sqlite3_column_blob(statement, 1), size > 0 {
                payload = Data(bytes: blob, count: size)
            } else {
                payload = Data()
            }
            results.append(StoredEvent(rowId: rowId, payload: payload))
        }
        return results
    }

    func delete(rowIds: [Int64]) throws {
        guard !rowIds.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let ids = rowIds.map(String.init).joined(separator: ",")
        try execute("DELETE FROM events WHERE id IN (\(ids));")
    }

    func count() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM events;")
    }

    func totalBytes() throws -> Int {
        try scalarInt("SELECT COALESCE(SUM(byte_size), 0) FROM events;")
    }

    /// Enforces max_queue_bytes by dropping the OLDEST events first, so
    /// fresh telemetry wins over stale telemetry when space runs out.
    func trim(toMaxBytes maxBytes: Int) throws -> Int {
        var dropped = 0
        while try totalBytes() > maxBytes {
            let victims = try oldest(limit: 25)
            if victims.isEmpty { break }
            try delete(rowIds: victims.map(\.rowId))
            dropped += victims.count
        }
        return dropped
    }

    private func scalarInt(_ sql: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(message())
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteError.stepFailed(message())
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.execFailed(message())
        }
    }

    private func message() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

enum SQLiteError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case execFailed(String)
}
