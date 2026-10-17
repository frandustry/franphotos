import Foundation
import Testing
@testable import FranPhotos

struct MonthKeyTests {
    @Test func parseAndFormat() {
        let key = MonthKey(parsing: "2025-03")
        #expect(key?.year == 2025)
        #expect(key?.month == 3)
        #expect(key?.description == "2025-03")
        #expect(MonthKey(parsing: "junk") == nil)
        #expect(MonthKey(parsing: "2025-13") == nil)
    }

    @Test func ordering() {
        #expect(MonthKey(parsing: "2024-12")! < MonthKey(parsing: "2025-01")!)
        #expect(MonthKey(parsing: "2025-03")! < MonthKey(parsing: "2025-04")!)
    }
}

struct ParquetSyncTests {
    private func makeLibrary() async throws -> (LibraryStore, DatabaseActor, ParquetSync, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LibraryStore.create(at: dir.appending(path: "Lib.franphotoslibrary"))
        let db = try await DatabaseActor.openOrCreate(at: store.paths.database)
        return (store, db, ParquetSync(db: db, paths: store.paths), dir)
    }

    private func insertAsset(_ db: DatabaseActor, uuid: UUID = UUID(),
                             capturedAt: Date, title: String? = nil) async throws -> Asset {
        var asset = Asset(
            uuid: uuid, mediaType: .photo, capturedAt: capturedAt, capturedAtTZOffset: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), durationMs: nil,
            width: 100, height: 100, fileSize: 100, sha256: uuid.uuidString + title.orEmpty,
            originalRelpath: "originals/2025/03/\(uuid.uuidString).jpg",
            filename: "\(uuid.uuidString).jpg", uti: nil,
            title: title, caption: nil,
            isFavorite: false, isHidden: false, isDeleted: false, deletedAt: nil, rating: 0,
            cameraMake: nil, cameraModel: nil, lensModel: nil, iso: nil,
            aperture: nil, shutterSpeed: nil, focalLength: nil,
            latitude: nil, longitude: nil, altitude: nil,
            hdrType: .sdr, isLivePhoto: false, livePhotoVideoRelpath: nil,
            livePhotoStillTimeMs: nil, videoCodec: nil, colorSpace: nil,
            hasAudio: nil, frameRate: nil, editRecipeJSON: nil, editVersion: 0)
        if let title { asset.title = title }
        try await db.execute(Asset.insertSQL, asset.insertBindings)
        return asset
    }

    @Test func indexAndMonthReadViaSQLiteFallback() async throws {
        let (store, db, sync, dir) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two months of data, no parquet yet → SQLite fallback path.
        let jan = Date(timeIntervalSince1970: 1737000000)   // 2025-01-16 UTC
        let mar = Date(timeIntervalSince1970: 1742000000)   // 2025-03-15 UTC
        _ = try await insertAsset(db, capturedAt: jan, title: "jan1")
        _ = try await insertAsset(db, capturedAt: jan + 3600, title: "jan2")
        _ = try await insertAsset(db, capturedAt: mar, title: "mar1")

        let index = try await sync.timelineIndex()
        #expect(index.count == 2)
        // Newest month first.
        #expect(index.first?.month == "2025-03" && index.first?.rowCount == 1)
        #expect(index.last?.month == "2025-01" && index.last?.rowCount == 2)

        let marAssets = try await sync.monthAssets(MonthKey(parsing: "2025-03")!)
        #expect(marAssets.count == 1)
        #expect(marAssets.first?.title == "mar1")
        _ = store
    }

    @Test func parquetRoundTripAndRepair() async throws {
        // Requires the fpparquet helper (skip gracefully when not built).
        guard ParquetHelperLocator.ensureBuilt() != nil else {
            return
        }
        let (store, db, sync, dir) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mar = Date(timeIntervalSince1970: 1742000000)
        let a = try await insertAsset(db, capturedAt: mar, title: "hello parquet")
        await sync.markDirty(months: [MonthKey(mar)])
        try await sync.syncTimeline()

        // Partition file written.
        let rel = LibraryPaths.timelineParquetRelativePath(monthKey: "2025-03")
        let fileURL = store.paths.url(forRelativePath: rel)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        // Magic bytes PAR1.
        let data = try Data(contentsOf: fileURL)
        #expect(data.prefix(4) == Data([0x50, 0x41, 0x52, 0x31]))

        // Index file written.
        #expect(FileManager.default.fileExists(atPath: store.paths.timelineIndexParquet.path))

        // Read back via parquet (drop DB row to prove parquet serves the data).
        try await db.execute("DELETE FROM assets WHERE uuid = ?", [.text(a.uuid.uuidString)])
        let assets = try await sync.monthAssets(MonthKey(parsing: "2025-03")!)
        // SQLite fallback would return 0 rows; parquet (written earlier) has 1.
        // But validate/repair would regenerate — monthAssets alone must return parquet content.
        #expect(assets.count == 1)
        #expect(assets.first?.title == "hello parquet")
        #expect(assets.first?.uuid == a.uuid)

        // Full validation notices the DB changed (dirty flag) and regenerates.
        await sync.markDirty(months: [MonthKey(mar)])
        try await sync.validateAndRepair()
        let after = try await sync.monthAssets(MonthKey(parsing: "2025-03")!)
        #expect(after.isEmpty)  // regenerated from DB (row deleted)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
