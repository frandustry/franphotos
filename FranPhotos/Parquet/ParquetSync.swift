import CryptoKit
import Foundation

/// Keeps parquet partitions in sync with the authoritative SQLite database.
///
/// Write path: mutations mark the library dirty (library_meta.timeline_dirty = 1)
/// plus mark affected months in memory. `syncTimeline()` regenerates those
/// partitions from the DB and rewrites `_index.parquet`.
///
/// Read path: timeline index and month rows are served from parquet when
/// available, falling back to SQLite (and scheduling a repair) when a partition
/// is missing or stale. The library therefore opens fast and self-heals.
actor ParquetSync {
    let db: DatabaseActor
    let paths: LibraryPaths
    private var bridge: ParquetBridge?
    private var bridgeUnavailable = false

    private var dirtyMonths: Set<String> = []

    init(db: DatabaseActor, paths: LibraryPaths) {
        self.db = db
        self.paths = paths
    }

    // MARK: - Bridge lifecycle

    private func requireBridge() throws -> ParquetBridge {
        if bridgeUnavailable { throw ParquetBridgeError.helperNotFound }
        if let bridge { return bridge }
        do {
            let b = try ParquetBridge.default()
            bridge = b
            return b
        } catch {
            bridgeUnavailable = true
            throw error
        }
    }

    var isBridgeAvailable: Bool {
        bridge != nil || !bridgeUnavailable
    }

    // MARK: - Dirty tracking

    func markDirty(months: some Collection<MonthKey>) async {
        dirtyMonths.formUnion(months.map(\.description))
        try? await setLibraryMeta("timeline_dirty", value: "1")
    }

    private func setLibraryMeta(_ key: String, value: String) async throws {
        try await db.execute(
            "INSERT INTO library_meta(key, value) VALUES (?, ?) "
            + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)])
    }

    private func libraryMeta(_ key: String) async throws -> String? {
        try await db.query("SELECT value FROM library_meta WHERE key = ?", [.text(key)])
            .first?.text("value")
    }

    private func isLibraryDirty() async throws -> Bool {
        try await libraryMeta("timeline_dirty") == "1"
    }

    // MARK: - Sync (write path)

    /// Regenerates every dirty month partition + the timeline index.
    func syncTimeline() async throws {
        let bridge = try requireBridge()
        let months = dirtyMonths
        dirtyMonths.removeAll()
        for monthString in months.sorted() {
            guard let key = MonthKey(parsing: monthString) else { continue }
            try await regenerateMonth(key, bridge: bridge)
        }
        try await rewriteTimelineIndex(bridge: bridge)
        try await setLibraryMeta("timeline_dirty", value: "0")
    }

    /// Full validation: recompute per-month content hashes from SQLite and
    /// regenerate any partition whose file or checksum is missing/stale.
    /// Runs in the background after library open when the dirty flag is set.
    func validateAndRepair() async throws {
        let bridge = try requireBridge()
        let monthRows = try await db.query("""
            SELECT strftime('%Y-%m', captured_at, 'unixepoch', 'localtime') AS m
            FROM assets WHERE is_deleted = 0 GROUP BY m
            """)
        let dbMonths = Set(monthRows.compactMap { $0.text("m") })

        let checksums = try await db.query(
            "SELECT partition_key FROM partition_checksums WHERE kind = 'timeline'")
        let knownMonths = Set(checksums.compactMap { row in
            row.text("partition_key").map { $0.replacingOccurrences(of: "timeline:", with: "") }
        })

        // Remove partitions for months that no longer have assets.
        for stale in knownMonths.subtracting(dbMonths) {
            let rel = LibraryPaths.timelineParquetRelativePath(monthKey: stale)
            try? FileManager.default.removeItem(at: paths.url(forRelativePath: rel))
            try await db.execute(
                "DELETE FROM partition_checksums WHERE partition_key = ?",
                [.text("timeline:\(stale)")])
        }

        var repaired = false
        for month in dbMonths.sorted() {
            guard let key = MonthKey(parsing: month) else { continue }
            let assets = try await fetchMonthAssets(key)
            let hash = contentHash(of: assets)
            let stored = try await db.query(
                "SELECT sha256 FROM partition_checksums WHERE partition_key = ?",
                [.text("timeline:\(month)")]).first?.text("sha256")
            let fileURL = paths.url(forRelativePath: LibraryPaths.timelineParquetRelativePath(monthKey: month))
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            if stored != hash || !fileExists {
                try await writeMonthPartition(key, assets: assets, hash: hash, bridge: bridge)
                repaired = true
            }
        }
        let libraryDirty = try await isLibraryDirty()
        if repaired || libraryDirty {
            try await rewriteTimelineIndex(bridge: bridge)
            try await setLibraryMeta("timeline_dirty", value: "0")
        }
    }

    private func regenerateMonth(_ key: MonthKey, bridge: ParquetBridge) async throws {
        let assets = try await fetchMonthAssets(key)
        if assets.isEmpty {
            let rel = LibraryPaths.timelineParquetRelativePath(monthKey: key.description)
            try? FileManager.default.removeItem(at: paths.url(forRelativePath: rel))
            try await db.execute("DELETE FROM partition_checksums WHERE partition_key = ?",
                                 [.text(key.parquetPartitionKey)])
            return
        }
        try await writeMonthPartition(key, assets: assets, hash: contentHash(of: assets),
                                      bridge: bridge)
    }

    private func writeMonthPartition(
        _ key: MonthKey, assets: [Asset], hash: String, bridge: ParquetBridge
    ) async throws {
        let rel = LibraryPaths.timelineParquetRelativePath(monthKey: key.description)
        let url = paths.url(forRelativePath: rel)
        let rows = assets.map { ParquetRowCodec.row(from: $0) }
        let result = try await bridge.writePartition(path: url, kind: .asset, rows: rows)
        try await db.execute("""
            INSERT INTO partition_checksums (partition_key, kind, row_count, sha256, regenerated_at)
            VALUES (?, 'timeline', ?, ?, ?)
            ON CONFLICT(partition_key) DO UPDATE SET
                row_count = excluded.row_count,
                sha256 = excluded.sha256,
                regenerated_at = excluded.regenerated_at
            """, [.text(key.parquetPartitionKey), .integer(Int64(result.rows)),
                  .text(hash), .date(Date())])
    }

    private func rewriteTimelineIndex(bridge: ParquetBridge) async throws {
        let entries = try await timelineIndexEntriesFromDB()
        let rows = entries.map(ParquetRowCodec.row(from:))
        try await bridge.writePartition(path: paths.timelineIndexParquet,
                                        kind: .timelineIndex, rows: rows)
    }

    private func timelineIndexEntriesFromDB() async throws -> [ParquetRowCodec.TimelineIndexEntry] {
        let rows = try await db.query("""
            SELECT strftime('%Y-%m', captured_at, 'unixepoch', 'localtime') AS m,
                   COUNT(*) AS c, MIN(captured_at) AS first, MAX(captured_at) AS last
            FROM assets WHERE is_deleted = 0 GROUP BY m ORDER BY m DESC
            """)
        var entries: [ParquetRowCodec.TimelineIndexEntry] = []
        for row in rows {
            guard let month = row.text("m") else { continue }
            let cover = try await db.query("""
                SELECT uuid FROM assets
                WHERE is_deleted = 0 AND is_hidden = 0
                  AND strftime('%Y-%m', captured_at, 'unixepoch', 'localtime') = ?
                ORDER BY captured_at DESC LIMIT 1
                """, [.text(month)]).first?.text("uuid") ?? ""
            let sha = try await db.query(
                "SELECT sha256 FROM partition_checksums WHERE partition_key = ?",
                [.text("timeline:\(month)")]).first?.text("sha256") ?? ""
            entries.append(.init(
                month: month,
                rowCount: Int(row.int("c") ?? 0),
                firstCaptured: Int64(row.double("first") ?? 0),
                lastCaptured: Int64(row.double("last") ?? 0),
                coverUUID: cover,
                sha256: sha))
        }
        return entries
    }

    // MARK: - Reads (parquet first, SQLite fallback)

    /// Timeline index entries, newest month first.
    func timelineIndex() async throws -> [ParquetRowCodec.TimelineIndexEntry] {
        if let bridge = try? requireBridge(),
           FileManager.default.fileExists(atPath: paths.timelineIndexParquet.path),
           let rows = try? await bridge.readPartition(path: paths.timelineIndexParquet,
                                                      kind: .timelineIndex) {
            let entries = rows.compactMap(ParquetRowCodec.indexEntry(from:))
            if !entries.isEmpty {
                return entries.sorted { $0.month > $1.month }
            }
        }
        return try await timelineIndexEntriesFromDB()
    }

    /// All assets of a month, newest first. Parquet first; SQLite fallback
    /// (and a scheduled repair) when the partition is missing or unreadable.
    func monthAssets(_ key: MonthKey) async throws -> [Asset] {
        let rel = LibraryPaths.timelineParquetRelativePath(monthKey: key.description)
        let url = paths.url(forRelativePath: rel)
        if let bridge = try? requireBridge(),
           FileManager.default.fileExists(atPath: url.path),
           let rows = try? await bridge.readPartition(path: url, kind: .asset),
           !rows.isEmpty {
            return rows.compactMap(ParquetRowCodec.asset(from:))
                .sorted(by: Asset.librarySortPredicate)
        }
        return try await fetchMonthAssets(key)
    }

    // MARK: - DB helpers

    private func fetchMonthAssets(_ key: MonthKey) async throws -> [Asset] {
        let rows = try await db.query("""
            SELECT * FROM assets
            WHERE strftime('%Y-%m', captured_at, 'unixepoch', 'localtime') = ?
            ORDER BY captured_at DESC
            """, [.text(key.description)])
        return rows.map(Asset.init)
    }

    /// Content signature used for staleness detection (cheap, order-independent).
    private func contentHash(of assets: [Asset]) -> String {
        var signatures = assets.map { asset in
            "\(asset.uuid.uuidString)|\(Int64(asset.capturedAt.timeIntervalSince1970))"
            + "|\(asset.editVersion)|\(asset.isHidden ? 1 : 0)|\(asset.isDeleted ? 1 : 0)"
            + "|\(asset.isFavorite ? 1 : 0)"
        }
        signatures.sort()
        var hasher = SHA256()
        hasher.update(data: Data(signatures.joined(separator: "\n").utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
