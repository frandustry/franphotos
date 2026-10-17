import Foundation

enum AlbumStoreError: LocalizedError {
    case albumNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .albumNotFound(let id): "Album not found: \(id)"
        }
    }
}

/// CRUD + membership for manual and smart albums.
struct AlbumStore: Sendable {
    let db: DatabaseActor

    // MARK: - Read

    func albums() async throws -> [Album] {
        try await db.query("SELECT * FROM albums ORDER BY sort_index, name")
            .map(Self.album(from:))
    }

    func album(_ uuid: UUID) async throws -> Album? {
        try await db.query("SELECT * FROM albums WHERE uuid = ?", [.text(uuid.uuidString)])
            .first.map(Self.album(from:))
    }

    func assetCount(in albumUUID: UUID) async throws -> Int {
        Int(try await db.scalarInt(
            "SELECT COUNT(*) FROM album_assets WHERE album_uuid = ?",
            [.text(albumUUID.uuidString)]))
    }

    /// Assets of an album in display order (manual sort, then newest first).
    func assets(in albumUUID: UUID) async throws -> [Asset] {
        guard let album = try await album(albumUUID) else {
            throw AlbumStoreError.albumNotFound(albumUUID)
        }
        if album.type == .smart, let json = album.smartRulesJSON,
           let rules = try? JSONDecoder().decode(SmartRuleSet.self, from: Data(json.utf8)) {
            let (whereSQL, bindings) = rules.sqlWhere()
            let rows = try await db.query("""
                SELECT * FROM assets
                WHERE is_deleted = 0 AND is_hidden = 0 AND \(whereSQL)
                ORDER BY captured_at DESC
                """, bindings)
            return rows.map(Asset.init)
        }
        let rows = try await db.query("""
            SELECT a.* FROM assets a
            JOIN album_assets aa ON aa.asset_uuid = a.uuid
            WHERE aa.album_uuid = ? AND a.is_deleted = 0
            ORDER BY aa.sort_index ASC, a.captured_at DESC
            """, [.text(albumUUID.uuidString)])
        return rows.map(Asset.init)
    }

    // MARK: - Create / update / delete

    @discardableResult
    func createAlbum(name: String, rules: SmartRuleSet? = nil) async throws -> Album {
        let album = Album(
            uuid: UUID(), name: name,
            type: rules == nil ? .manual : .smart,
            smartRulesJSON: rules.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) },
            sortIndex: 0, coverAssetUUID: nil)
        try await db.execute(
            "INSERT INTO albums(uuid, name, type, smart_rules_json, sort_index) VALUES (?, ?, ?, ?, 0)",
            [.text(album.uuid.uuidString), .text(name), .text(album.type.rawValue),
             .optionalText(album.smartRulesJSON)])
        return album
    }

    func renameAlbum(_ uuid: UUID, to name: String) async throws {
        try await db.execute("UPDATE albums SET name = ? WHERE uuid = ?",
                             [.text(name), .text(uuid.uuidString)])
    }

    func deleteAlbum(_ uuid: UUID) async throws {
        try await db.execute("DELETE FROM albums WHERE uuid = ?", [.text(uuid.uuidString)])
        try await db.execute("DELETE FROM partition_checksums WHERE partition_key = ?",
                             [.text("album:\(uuid.uuidString)")])
    }

    // MARK: - Membership

    func add(_ assetUUIDs: [UUID], to albumUUID: UUID) async throws {
        let maxSort = try await db.scalarInt(
            "SELECT COALESCE(MAX(sort_index), -1) FROM album_assets WHERE album_uuid = ?",
            [.text(albumUUID.uuidString)])
        try await db.transaction { db in
            for (offset, uuid) in assetUUIDs.enumerated() {
                try db.execute("""
                    INSERT OR IGNORE INTO album_assets(album_uuid, asset_uuid, sort_index)
                    VALUES (?, ?, ?)
                    """, [.text(albumUUID.uuidString), .text(uuid.uuidString),
                          .integer(maxSort + Int64(offset) + 1)])
            }
        }
    }

    func remove(_ assetUUIDs: [UUID], from albumUUID: UUID) async throws {
        try await db.transaction { db in
            for uuid in assetUUIDs {
                try db.execute(
                    "DELETE FROM album_assets WHERE album_uuid = ? AND asset_uuid = ?",
                    [.text(albumUUID.uuidString), .text(uuid.uuidString)])
            }
        }
    }

    /// Albums containing an asset (used by the info panel later).
    func albums(containing assetUUID: UUID) async throws -> [Album] {
        try await db.query("""
            SELECT al.* FROM albums al
            JOIN album_assets aa ON aa.album_uuid = al.uuid
            WHERE aa.asset_uuid = ? ORDER BY al.name
            """, [.text(assetUUID.uuidString)]).map(Self.album(from:))
    }

    // MARK: - Mapping

    static func album(from row: SQLRow) -> Album {
        Album(
            uuid: UUID(uuidString: row.text("uuid") ?? "") ?? UUID(),
            name: row.text("name") ?? "",
            type: AlbumType(rawValue: row.text("type") ?? "manual") ?? .manual,
            smartRulesJSON: row.text("smart_rules_json"),
            sortIndex: Int(row.int("sort_index") ?? 0),
            coverAssetUUID: row.text("cover_asset_uuid").flatMap(UUID.init(uuidString:))
        )
    }
}
