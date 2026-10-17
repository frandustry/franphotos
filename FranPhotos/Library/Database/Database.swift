import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String, sql: String)
    case stepFailed(String)
    case execFailed(String, sql: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): "Failed to open database: \(m)"
        case .prepareFailed(let m, let sql): "Failed to prepare statement: \(m) — SQL: \(sql)"
        case .stepFailed(let m): "Failed to execute statement: \(m)"
        case .execFailed(let m, let sql): "Failed to execute SQL: \(m) — SQL: \(sql)"
        }
    }
}

/// Thin synchronous wrapper over the system libsqlite3 (FTS5-enabled).
/// Not thread-safe by itself — always accessed through `DatabaseActor`.
final class Database {
    private var handle: OpaquePointer?

    init(path: URL) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            throw DatabaseError.openFailed(message)
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA busy_timeout = 5000")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changedRowCount: Int { Int(sqlite3_changes(handle)) }

    // MARK: - Statement helpers

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: SQLValue, to stmt: OpaquePointer?, at index: Int32) {
        switch value {
        case .null:
            sqlite3_bind_null(stmt, index)
        case .integer(let v):
            sqlite3_bind_int64(stmt, index, v)
        case .double(let v):
            sqlite3_bind_double(stmt, index, v)
        case .text(let v):
            sqlite3_bind_text(stmt, index, v, -1, Database.transientDestructor)
        case .blob(let v):
            v.withUnsafeBytes { buf in
                _ = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), Database.transientDestructor)
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(errorMessage, sql: sql)
        }
        return stmt
    }

    private var errorMessage: String {
        sqlite3_errmsg(handle).map { String(cString: $0) } ?? "unknown error"
    }

    /// Runs a statement that returns no rows (INSERT/UPDATE/DELETE/DDL).
    @discardableResult
    func execute(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, b) in bindings.enumerated() {
            bind(b, to: stmt, at: Int32(i + 1))
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw DatabaseError.stepFailed("\(errorMessage) (rc=\(rc)) — SQL: \(sql)")
        }
        return changedRowCount
    }

    /// Runs a query and returns all rows.
    func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, b) in bindings.enumerated() {
            bind(b, to: stmt, at: Int32(i + 1))
        }
        var rows: [SQLRow] = []
        let columnCount = sqlite3_column_count(stmt)
        var columnNames: [String] = []
        columnNames.reserveCapacity(Int(columnCount))
        for i in 0..<columnCount {
            let name = sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "col\(i)"
            columnNames.append(name)
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var values: [SQLValue] = []
                values.reserveCapacity(Int(columnCount))
                for i in 0..<columnCount {
                    values.append(Self.columnValue(stmt, i))
                }
                rows.append(SQLRow(columns: columnNames, values: values))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.stepFailed("\(errorMessage) (rc=\(rc)) — SQL: \(sql)")
            }
        }
        return rows
    }

    private static func columnValue(_ stmt: OpaquePointer?, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT:
            if let cstr = sqlite3_column_text(stmt, i) {
                return .text(String(cString: cstr))
            }
            return .text("")
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(stmt, i))
            if count > 0, let bytes = sqlite3_column_blob(stmt, i) {
                return .blob(Data(bytes: bytes, count: count))
            }
            return .blob(Data())
        default:
            return .null
        }
    }

    /// Executes a (possibly multi-statement) SQL script. Used by migrations.
    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw DatabaseError.execFailed(message, sql: sql)
        }
    }

    /// Runs `block` inside BEGIN IMMEDIATE … COMMIT, rolling back on error.
    func transaction<T>(_ block: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try block()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Convenience for scalar queries (COUNT etc.).
    func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64 {
        try query(sql, bindings).first?.values.first?.intValue ?? 0
    }
}
