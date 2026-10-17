import Foundation

/// Serializes all access to the SQLite database. Every layer above
/// (repositories, import engine, parquet sync) talks to this actor only.
actor DatabaseActor {
    let path: URL
    private let db: Database

    init(path: URL) throws {
        self.path = path
        self.db = try Database(path: path)
    }

    /// Creates the database file (and parent directory) if needed, then migrates.
    static func openOrCreate(at path: URL) async throws -> DatabaseActor {
        let fm = FileManager.default
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let actor = try DatabaseActor(path: path)
        try await actor.migrate()
        return actor
    }

    @discardableResult
    func migrate() throws -> [Int] {
        try Migrations.apply(to: db)
    }

    func schemaVersion() throws -> Int {
        try Migrations.currentVersion(of: db)
    }

    // MARK: - Pass-through primitives

    @discardableResult
    func execute(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        try db.execute(sql, bindings)
    }

    func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        try db.query(sql, bindings)
    }

    func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64 {
        try db.scalarInt(sql, bindings)
    }

    func transaction<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try db.transaction { try block(db) }
    }
}
