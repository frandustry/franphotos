import Foundation
import SwiftUI

/// Observable album list for the sidebar; mutating goes through AlbumStore and
/// marks the album's parquet partition dirty.
@MainActor
@Observable
final class AlbumsStore {
    private(set) var albums: [Album] = []
    private let db: DatabaseActor
    private let sync: ParquetSync

    private var store: AlbumStore { AlbumStore(db: db) }

    init(db: DatabaseActor, sync: ParquetSync) {
        self.db = db
        self.sync = sync
    }

    func reload() async {
        albums = (try? await store.albums()) ?? []
    }

    @discardableResult
    func createAlbum(name: String, rules: SmartRuleSet? = nil) async -> Album? {
        guard let album = try? await store.createAlbum(name: name, rules: rules) else {
            return nil
        }
        await reload()
        return album
    }

    func rename(_ uuid: UUID, to name: String) async {
        try? await store.renameAlbum(uuid, to: name)
        await reload()
    }

    func delete(_ uuid: UUID) async {
        try? await store.deleteAlbum(uuid)
        await sync.markAlbumDirty(uuid)
        try? await sync.syncAlbums()
        await reload()
    }

    func add(_ assetUUIDs: [UUID], to albumUUID: UUID) async {
        try? await store.add(assetUUIDs, to: albumUUID)
        await sync.markAlbumDirty(albumUUID)
        try? await sync.syncAlbums()
        await reload()
    }

    func remove(_ assetUUIDs: [UUID], from albumUUID: UUID) async {
        try? await store.remove(assetUUIDs, from: albumUUID)
        await sync.markAlbumDirty(albumUUID)
        try? await sync.syncAlbums()
        await reload()
    }
}
