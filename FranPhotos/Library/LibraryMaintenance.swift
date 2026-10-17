import Foundation

/// Housekeeping: permanently purges assets that have been in Recently Deleted
/// for over 30 days (row + original + live-photo component + derivatives + faces).
struct LibraryMaintenance: Sendable {
    static let retentionSeconds: TimeInterval = 30 * 24 * 3600

    /// Purges expired trash. Returns purged UUIDs.
    @discardableResult
    static func purgeExpiredTrash(db: DatabaseActor, paths: LibraryPaths) async throws -> [UUID] {
        let cutoff = Date().timeIntervalSince1970 - retentionSeconds
        let rows = try await db.query(
            "SELECT uuid, original_relpath, live_photo_video_relpath FROM assets "
            + "WHERE is_deleted = 1 AND deleted_at IS NOT NULL AND deleted_at < ?",
            [.double(cutoff)])
        guard !rows.isEmpty else { return [] }

        let fm = FileManager.default
        var purged: [UUID] = []
        for row in rows {
            guard let uuidString = row.text("uuid"), let uuid = UUID(uuidString: uuidString)
            else { continue }
            for rel in [row.text("original_relpath"), row.text("live_photo_video_relpath")].compactMap({ $0 }) {
                try? fm.removeItem(at: paths.url(forRelativePath: rel))
            }
            try? fm.removeItem(at: DerivativeSize.thumb.url(for: uuid, in: paths))
            try? fm.removeItem(at: DerivativeSize.screen.url(for: uuid, in: paths))
            try? fm.removeItem(at: paths.editsDirectory.appending(path: uuidString, directoryHint: .isDirectory))
            try await db.execute("DELETE FROM assets WHERE uuid = ?", [.text(uuidString)])
            purged.append(uuid)
        }
        return purged
    }

    /// Days remaining before an asset in trash is purged.
    static func daysUntilPurge(deletedAt: Date, now: Date = Date()) -> Int {
        let elapsed = now.timeIntervalSince(deletedAt)
        return max(0, Int((retentionSeconds - elapsed) / 86400))
    }
}
