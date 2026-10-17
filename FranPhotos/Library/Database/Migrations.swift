import Foundation

struct Migration: Sendable {
    let version: Int
    let name: String
    let sql: String
}

/// Ordered, append-only list of schema migrations.
enum Migrations {
    static let all: [Migration] = [
        Migration(version: 1, name: "initial schema", sql: SchemaV1.sql),
    ]

    /// Applies all pending migrations, each in its own transaction.
    /// Returns the versions that were applied during this call.
    @discardableResult
    static func apply(to db: Database) throws -> [Int] {
        // schema_migrations may not exist yet on a brand-new database.
        try db.exec("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
            )
            """)
        let appliedRows = try db.query("SELECT version FROM schema_migrations")
        let applied = Set(appliedRows.compactMap { $0.int("version") }.map(Int.init))
        var newlyApplied: [Int] = []
        for migration in all where !applied.contains(migration.version) {
            try db.transaction {
                try db.exec(migration.sql)
                try db.execute(
                    "INSERT INTO schema_migrations (version, name) VALUES (?, ?)",
                    [.integer(Int64(migration.version)), .text(migration.name)]
                )
            }
            newlyApplied.append(migration.version)
        }
        return newlyApplied
    }

    static func currentVersion(of db: Database) throws -> Int {
        let rows = try db.query(
            "SELECT COALESCE(MAX(version), 0) AS v FROM schema_migrations"
        )
        return Int(rows.first?.int("v") ?? 0)
    }
}
