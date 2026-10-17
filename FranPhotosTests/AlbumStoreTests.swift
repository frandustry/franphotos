import Foundation
import Testing
@testable import FranPhotos

struct AlbumStoreTests {
    private func makeLibrary() async throws -> (LibraryStore, DatabaseActor, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LibraryStore.create(at: dir.appending(path: "Lib.franphotoslibrary"))
        let db = try await DatabaseActor.openOrCreate(at: store.paths.database)
        return (store, db, dir)
    }

    private func insertAsset(_ db: DatabaseActor, uuid: UUID = UUID(),
                             mediaType: MediaType = .photo,
                             isFavorite: Bool = false, capturedAt: Date = Date(timeIntervalSince1970: 1_740_000_000)) async throws -> UUID {
        let asset = Asset(
            uuid: uuid, mediaType: mediaType, capturedAt: capturedAt, capturedAtTZOffset: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), durationMs: nil,
            width: 100, height: 100, fileSize: 100, sha256: uuid.uuidString,
            originalRelpath: "originals/x/\(uuid).jpg", filename: "\(uuid).jpg", uti: nil,
            title: nil, caption: nil,
            isFavorite: isFavorite, isHidden: false, isDeleted: false, deletedAt: nil, rating: 0,
            cameraMake: nil, cameraModel: "iPhone 15 Pro", lensModel: nil, iso: nil,
            aperture: nil, shutterSpeed: nil, focalLength: nil,
            latitude: nil, longitude: nil, altitude: nil,
            hdrType: .sdr, isLivePhoto: false, livePhotoVideoRelpath: nil,
            livePhotoStillTimeMs: nil, videoCodec: nil, colorSpace: nil,
            hasAudio: nil, frameRate: nil, editRecipeJSON: nil, editVersion: 0)
        try await db.execute(Asset.insertSQL, asset.insertBindings)
        return uuid
    }

    @Test func manualAlbumMembership() async throws {
        let (_, db, dir) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AlbumStore(db: db)
        let album = try await store.createAlbum(name: "Trips")
        let a = try await insertAsset(db)
        let b = try await insertAsset(db)
        try await store.add([a, b], to: album.uuid)

        let assets = try await store.assets(in: album.uuid)
        #expect(assets.count == 2)
        // Order: insertion order via sort_index.
        #expect(assets.map(\.uuid) == [a, b])

        try await store.remove([a], from: album.uuid)
        #expect(try await store.assets(in: album.uuid).count == 1)
        #expect(try await store.albums(containing: b).map(\.uuid) == [album.uuid])

        try await store.deleteAlbum(album.uuid)
        #expect(try await store.albums().isEmpty)
    }

    @Test func smartAlbumRulesCompileAndMatch() async throws {
        let (_, db, dir) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AlbumStore(db: db)

        _ = try await insertAsset(db, mediaType: .video)
        _ = try await insertAsset(db, mediaType: .photo, isFavorite: true)
        _ = try await insertAsset(db, mediaType: .photo, isFavorite: false)

        var rules = SmartRuleSet()
        rules.match = .all
        rules.conditions = [
            .init(field: .mediaType, op: .isEqual, value: "photo"),
            .init(field: .isFavorite, op: .isEqual, value: "1"),
        ]
        let album = try await store.createAlbum(name: "Favorite Photos", rules: rules)
        let assets = try await store.assets(in: album.uuid)
        #expect(assets.count == 1)
        #expect(assets.first?.isFavorite == true)
    }

    @Test func sqlWhereIsParameterized() {
        var rules = SmartRuleSet()
        rules.conditions = [
            .init(field: .cameraModel, op: .contains, value: "'; DROP TABLE assets; --"),
            .init(field: .keyword, op: .contains, value: "beach"),
        ]
        let (sql, bindings) = rules.sqlWhere()
        #expect(!sql.contains("DROP TABLE"))
        #expect(bindings.count == 2)
        #expect(bindings.first?.textValue == "%'; DROP TABLE assets; --%")
    }

    @Test func albumParquetSnapshot() async throws {
        guard ParquetHelperLocator.ensureBuilt() != nil else { return }
        let (store, db, dir) = try await makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sync = ParquetSync(db: db, paths: store.paths)
        let albumStore = AlbumStore(db: db)
        let album = try await albumStore.createAlbum(name: "Snapshot Test")
        let a = try await insertAsset(db)
        try await albumStore.add([a], to: album.uuid)

        await sync.markAlbumDirty(album.uuid)
        try await sync.syncAlbums()

        let file = store.paths.albumsParquetDirectory
            .appending(path: "\(album.uuid.uuidString).parquet")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: store.paths.albumsIndexParquet.path))
    }
}
