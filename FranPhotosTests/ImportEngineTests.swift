import Foundation
import Testing
@testable import FranPhotos

struct ImportEngineTests {
    private func makeLibrary() throws -> (LibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LibraryStore.create(at: dir.appending(path: "Lib.franphotoslibrary"))
        return (store, dir)
    }

    @Test func importsPhotoWithEXIF() async throws {
        let (store, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await DatabaseActor.openOrCreate(at: store.paths.database)

        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let jpeg = try TestFixtures.makeJPEG(in: src, name: "IMG_0001.jpg", exif: .init(
            dateTimeOriginal: "2025:03:14 10:30:00",
            offsetTimeOriginal: "+08:00",
            latitude: 31.2304, longitude: 121.4737
        ))

        let engine = ImportEngine(library: store, db: db)
        let outcome = await engine.importFiles([src]) { _ in }

        #expect(outcome.importedUUIDs.count == 1)
        #expect(outcome.failures.isEmpty)

        let rows = try await db.query("SELECT * FROM assets")
        #expect(rows.count == 1)
        let asset = Asset(row: rows[0])
        #expect(asset.mediaType == .photo)
        #expect(asset.cameraMake == "Apple")
        #expect(asset.cameraModel == "iPhone 15 Pro")
        #expect(asset.capturedAtTZOffset == 28800)
        #expect(asset.latitude != nil && abs(asset.latitude! - 31.2304) < 0.0001)
        #expect(asset.longitude != nil && abs(asset.longitude! - 121.4737) < 0.0001)

        // EXIF date parsed in +08:00 → 2025-03-14 10:30:00 +0800 = 02:30 UTC.
        let expected = Date(timeIntervalSince1970: 1741919400)
        #expect(abs(asset.capturedAt.timeIntervalSince(expected)) < 2)

        // Original physically copied into the bundle, date-partitioned.
        #expect(asset.originalRelpath.hasPrefix("originals/2025/03/"))
        #expect(FileManager.default.fileExists(
            atPath: store.paths.url(forRelativePath: asset.originalRelpath).path))
        _ = jpeg
    }

    @Test func dedupesBySHA256() async throws {
        let (store, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await DatabaseActor.openOrCreate(at: store.paths.database)
        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let a = try TestFixtures.makeJPEG(in: src, name: "a.jpg")
        let b = dir.appending(path: "b.jpg")
        try FileManager.default.copyItem(at: a, to: b)  // same bytes, different name

        let engine = ImportEngine(library: store, db: db)
        let outcome = await engine.importFiles([a, b]) { _ in }
        #expect(outcome.importedUUIDs.count == 1)
        #expect(outcome.duplicateCount == 1)
    }

    @Test func importsVideoWithMetadata() async throws {
        let (store, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await DatabaseActor.openOrCreate(at: store.paths.database)
        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let video = try await TestFixtures.makeVideo(in: src, name: "clip.mov", durationSeconds: 2.0)

        let engine = ImportEngine(library: store, db: db)
        let outcome = await engine.importFiles([video]) { _ in }
        #expect(outcome.importedUUIDs.count == 1)

        let rows = try await db.query("SELECT * FROM assets")
        let asset = try #require(rows.first.map(Asset.init))
        #expect(asset.mediaType == .video)
        #expect(asset.durationMs != nil && abs((asset.durationMs ?? 0) - 2000) < 500)
        #expect(asset.width == 320 && asset.height == 240)
        #expect(asset.videoCodec != nil)
    }

    @Test func livePhotoPairingByStem() async throws {
        let (store, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await DatabaseActor.openOrCreate(at: store.paths.database)
        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        // IMG_0002.HEIC-style pair: same stem, short video.
        let photo = try TestFixtures.makeJPEG(in: src, name: "IMG_0002.jpg")
        _ = try await TestFixtures.makeVideo(in: src, name: "IMG_0002.mov", durationSeconds: 1.5)
        // Long video with same stem as another photo → NOT paired (it's a real video).
        _ = try TestFixtures.makeJPEG(in: src, name: "IMG_0003.jpg")
        _ = try await TestFixtures.makeVideo(in: src, name: "IMG_0003.mov", durationSeconds: 8.0)

        let engine = ImportEngine(library: store, db: db)
        let outcome = await engine.importFiles([src]) { _ in }
        // 1 live photo + 1 photo + 1 video = 3 assets.
        #expect(outcome.importedUUIDs.count == 3)

        let rows = try await db.query("SELECT * FROM assets")
        let assets = rows.map(Asset.init)
        let live = assets.filter(\.isLivePhoto)
        #expect(live.count == 1)
        #expect(live.first?.filename == "IMG_0002.jpg")
        #expect(live.first?.livePhotoVideoRelpath?.hasSuffix(".mov") == true)
        // The live video component physically exists next to the still.
        if let rel = live.first?.livePhotoVideoRelpath {
            #expect(FileManager.default.fileExists(
                atPath: store.paths.url(forRelativePath: rel).path))
        }
        // Long video imported as standalone video.
        #expect(assets.filter { $0.mediaType == .video }.count == 1)
        _ = photo
    }

    @Test func parsesExifDatesAndOffsets() {
        let date = MetadataExtractor.parseExifDate("2024:12:31 23:59:58", tzOffsetSeconds: 3600)
        #expect(date != nil)
        #expect(abs(date!.timeIntervalSince1970 - 1735685998) < 2)
        #expect(MetadataExtractor.parseOffset("+08:00") == 28800)
        #expect(MetadataExtractor.parseOffset("-05:30") == -19800)
        #expect(MetadataExtractor.parseOffset("junk") == nil)
    }
}
