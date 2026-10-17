import Foundation
import Testing
@testable import FranPhotos

struct DatabaseTests {
    private func makeActor() async throws -> (DatabaseActor, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let actor = try await DatabaseActor.openOrCreate(at: dir.appending(path: "library.sqlite"))
        return (actor, dir)
    }

    private func sampleAsset(uuid: UUID = UUID()) -> Asset {
        Asset(
            uuid: uuid, mediaType: .photo, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            capturedAtTZOffset: 28800, addedAt: Date(timeIntervalSince1970: 1_700_100_000), durationMs: nil,
            width: 4032, height: 3024, fileSize: 3_500_000, sha256: uuid.uuidString,
            originalRelpath: "originals/2023/11/\(uuid.uuidString).heic",
            filename: "IMG_0001.heic", uti: "public.heic",
            title: nil, caption: nil,
            isFavorite: false, isHidden: false, isDeleted: false, deletedAt: nil, rating: 0,
            cameraMake: "Apple", cameraModel: "iPhone 15 Pro", lensModel: "wide",
            iso: 64, aperture: 1.78, shutterSpeed: 1.0 / 120.0, focalLength: 6.86,
            latitude: 31.2304, longitude: 121.4737, altitude: 12.0,
            hdrType: .gainmap, isLivePhoto: false,
            livePhotoVideoRelpath: nil, livePhotoStillTimeMs: nil,
            videoCodec: nil, colorSpace: nil, hasAudio: nil, frameRate: nil,
            editRecipeJSON: nil, editVersion: 0
        )
    }

    @Test func migrationsApplyOnce() async throws {
        let (actor, dir) = try await makeActor()
        defer { try? FileManager.default.removeItem(at: dir) }
        let version = try await actor.schemaVersion()
        #expect(version == Migrations.all.map(\.version).max())
        // Idempotent: migrating again applies nothing.
        let reapplied = try await actor.migrate()
        #expect(reapplied.isEmpty)
    }

    @Test func assetInsertRoundTrip() async throws {
        let (actor, dir) = try await makeActor()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = sampleAsset()
        try await actor.execute(Asset.insertSQL, asset.insertBindings)
        let rows = try await actor.query("SELECT * FROM assets WHERE uuid = ?", [.text(asset.uuid.uuidString)])
        #expect(rows.count == 1)
        let decoded = Asset(row: rows[0])
        #expect(decoded == asset)
    }

    @Test func sha256UniqueConstraint() async throws {
        let (actor, dir) = try await makeActor()
        defer { try? FileManager.default.removeItem(at: dir) }
        let uuid = UUID()
        try await actor.execute(Asset.insertSQL, sampleAsset(uuid: uuid).insertBindings)
        // Same sha256 (sampleAsset uses uuid string as sha) → constraint violation.
        await #expect(throws: DatabaseError.self) {
            try await actor.execute(Asset.insertSQL, sampleAsset(uuid: uuid).insertBindings)
        }
    }

    @Test func ftsTriggerSyncAndSearch() async throws {
        let (actor, dir) = try await makeActor()
        defer { try? FileManager.default.removeItem(at: dir) }
        var asset = sampleAsset()
        asset.title = "Sunset over the Bund"
        try await actor.execute(Asset.insertSQL, asset.insertBindings)
        let hits = try await actor.query("""
            SELECT a.uuid FROM asset_fts JOIN assets a ON a.rowid = asset_fts.rowid
            WHERE asset_fts MATCH ?
            """, [.text("sunset")])
        #expect(hits.count == 1)
        // Update propagates through trigger.
        try await actor.execute("UPDATE assets SET title = 'Night skyline' WHERE uuid = ?",
                                [.text(asset.uuid.uuidString)])
        let old = try await actor.query("SELECT rowid FROM asset_fts WHERE asset_fts MATCH 'sunset'")
        let new = try await actor.query("SELECT rowid FROM asset_fts WHERE asset_fts MATCH 'skyline'")
        #expect(old.isEmpty)
        #expect(new.count == 1)
    }

    @Test func libraryViewIndexExcludesHiddenAndDeleted() async throws {
        let (actor, dir) = try await makeActor()
        defer { try? FileManager.default.removeItem(at: dir) }
        var hidden = sampleAsset()
        hidden.isHidden = true
        var deleted = sampleAsset()
        deleted.isDeleted = true
        try await actor.execute(Asset.insertSQL, sampleAsset().insertBindings)
        try await actor.execute(Asset.insertSQL, hidden.insertBindings)
        try await actor.execute(Asset.insertSQL, deleted.insertBindings)
        let count = try await actor.scalarInt(
            "SELECT COUNT(*) FROM assets WHERE is_deleted = 0 AND is_hidden = 0")
        #expect(count == 1)
    }
}
