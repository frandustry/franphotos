import Foundation

/// All user-initiated asset mutations. Each writes SQLite (authoritative),
/// marks affected timeline partitions dirty for the parquet layer, and keeps
/// the FTS keywords column in sync (contentless FTS5 needs full-row rewrite).
struct AssetActions: Sendable {
    let db: DatabaseActor

    // MARK: - Title / caption

    func updateTitleCaption(uuid: UUID, title: String?, caption: String?) async throws {
        try await db.execute(
            "UPDATE assets SET title = ?, caption = ? WHERE uuid = ?",
            [.optionalText(title?.isEmpty == true ? nil : title),
             .optionalText(caption?.isEmpty == true ? nil : caption),
             .text(uuid.uuidString)])
    }

    // MARK: - Favorite / hidden / deleted

    func setFavorite(_ uuid: UUID, _ value: Bool) async throws {
        try await db.execute("UPDATE assets SET is_favorite = ? WHERE uuid = ?",
                             [.bool(value), .text(uuid.uuidString)])
    }

    func setHidden(_ uuid: UUID, _ value: Bool) async throws {
        try await db.execute("UPDATE assets SET is_hidden = ? WHERE uuid = ?",
                             [.bool(value), .text(uuid.uuidString)])
    }

    /// Moves to Recently Deleted (recoverable for 30 days — see LibraryMaintenance).
    func moveToTrash(_ uuid: UUID) async throws {
        try await db.execute(
            "UPDATE assets SET is_deleted = 1, deleted_at = ? WHERE uuid = ?",
            [.date(Date()), .text(uuid.uuidString)])
    }

    func restoreFromTrash(_ uuid: UUID) async throws {
        try await db.execute(
            "UPDATE assets SET is_deleted = 0, deleted_at = NULL WHERE uuid = ?",
            [.text(uuid.uuidString)])
    }

    /// Permanently deletes: row + original file + live photo component + derivatives.
    /// File removal is performed by the caller's library paths.
    func deletePermanently(_ uuid: UUID) async throws {
        try await db.execute("DELETE FROM assets WHERE uuid = ?", [.text(uuid.uuidString)])
    }

    // MARK: - Keywords

    func setKeywords(_ uuid: UUID, keywords: [String]) async throws {
        let clean = keywords.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        try await db.transaction { db in
            try db.execute("DELETE FROM asset_keywords WHERE asset_uuid = ?",
                           [.text(uuid.uuidString)])
            for name in clean {
                let existing = try db.query("SELECT uuid FROM keywords WHERE name = ?",
                                            [.text(name)]).first?.text("uuid")
                let keywordUUID: String
                if let existing {
                    keywordUUID = existing
                } else {
                    keywordUUID = UUID().uuidString
                    try db.execute("INSERT INTO keywords(uuid, name) VALUES (?, ?)",
                                   [.text(keywordUUID), .text(name)])
                }
                try db.execute(
                    "INSERT OR IGNORE INTO asset_keywords(asset_uuid, keyword_uuid) VALUES (?, ?)",
                    [.text(uuid.uuidString), .text(keywordUUID)])
            }
            // Refresh the FTS keywords column (contentless → delete + reinsert).
            try db.execute(
                "DELETE FROM asset_fts WHERE rowid = (SELECT rowid FROM assets WHERE uuid = ?)",
                [.text(uuid.uuidString)])
            try db.execute("""
                INSERT INTO asset_fts(rowid, title, caption, keywords, filename)
                SELECT a.rowid, coalesce(a.title,''), coalesce(a.caption,''),
                       coalesce((SELECT group_concat(k.name, ' ')
                                   FROM asset_keywords ak JOIN keywords k
                                     ON k.uuid = ak.keyword_uuid
                                  WHERE ak.asset_uuid = a.uuid), ''),
                       a.filename
                FROM assets a WHERE a.uuid = ?
                """, [.text(uuid.uuidString)])
        }
    }

    func keywords(for uuid: UUID) async throws -> [String] {
        try await db.query("""
            SELECT k.name FROM asset_keywords ak
            JOIN keywords k ON k.uuid = ak.keyword_uuid
            WHERE ak.asset_uuid = ? ORDER BY k.name
            """, [.text(uuid.uuidString)]).compactMap { $0.text("name") }
    }

    func allKeywords() async throws -> [String] {
        try await db.query("SELECT name FROM keywords ORDER BY name")
            .compactMap { $0.text("name") }
    }

    // MARK: - Edit recipes

    /// Stores a new edit recipe version (non-destructive; original untouched).
    func setEditRecipe(_ uuid: UUID, recipeJSON: String?, version: Int) async throws {
        try await db.execute(
            "UPDATE assets SET edit_recipe_json = ?, edit_version = ? WHERE uuid = ?",
            [.optionalText(recipeJSON), .integer(Int64(version)), .text(uuid.uuidString)])
    }

    // MARK: - Date & location

    /// Adjusts capture date. `tzOffsetSeconds` replaces the stored offset when non-nil.
    func setCapturedAt(_ uuid: UUID, date: Date, tzOffsetSeconds: Int?) async throws {
        try await db.execute(
            "UPDATE assets SET captured_at = ?, captured_at_tz_offset = ? WHERE uuid = ?",
            [.date(date),
             tzOffsetSeconds.map { SQLValue.integer(Int64($0)) } ?? .null,
             .text(uuid.uuidString)])
    }

    func setLocation(_ uuid: UUID, latitude: Double?, longitude: Double?, altitude: Double? = nil) async throws {
        try await db.execute(
            "UPDATE assets SET latitude = ?, longitude = ?, altitude = ? WHERE uuid = ?",
            [latitude.map { SQLValue.double($0) } ?? .null,
             longitude.map { SQLValue.double($0) } ?? .null,
             altitude.map { SQLValue.double($0) } ?? .null,
             .text(uuid.uuidString)])
    }

    // MARK: - Reads

    func fetch(_ uuid: UUID) async throws -> Asset? {
        try await db.query("SELECT * FROM assets WHERE uuid = ?",
                           [.text(uuid.uuidString)]).first.map(Asset.init)
    }

    /// Month key of an asset (for dirty marking).
    func monthKey(of uuid: UUID) async throws -> MonthKey? {
        try await fetch(uuid).map { MonthKey($0.capturedAt) }
    }
}
