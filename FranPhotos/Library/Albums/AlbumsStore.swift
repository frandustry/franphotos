import Foundation
import SwiftUI

/// Observable album/folder list for the sidebar; mutating goes through
/// AlbumStore and marks the album's parquet partition dirty.
@MainActor
@Observable
final class AlbumsStore {
    private(set) var albums: [Album] = []
    private(set) var folders: [AlbumFolder] = []
    private let db: DatabaseActor
    private let sync: ParquetSync

    private var store: AlbumStore { AlbumStore(db: db) }

    init(db: DatabaseActor, sync: ParquetSync) {
        self.db = db
        self.sync = sync
    }

    func reload() async {
        albums = (try? await store.albums()) ?? []
        folders = (try? await store.folders()) ?? []
    }

    @discardableResult
    func createAlbum(name: String, rules: SmartRuleSet? = nil,
                     in folderUUID: UUID? = nil) async -> Album? {
        guard let album = try? await store.createAlbum(name: name, rules: rules,
                                                       in: folderUUID) else {
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

    // MARK: - Folders

    @discardableResult
    func createFolder(name: String, parent: UUID? = nil) async -> AlbumFolder? {
        guard let folder = try? await store.createFolder(name: name, parent: parent)
        else { return nil }
        await reload()
        return folder
    }

    func renameFolder(_ uuid: UUID, to name: String) async {
        try? await store.renameFolder(uuid, to: name)
        await reload()
    }

    /// Deletes the folder and everything in it (albums + subfolders), like
    /// Apple Photos; contained assets stay in the library.
    func deleteFolder(_ uuid: UUID) async {
        let doomedAlbums = (try? await store.deleteFolderRecursively(uuid)) ?? []
        for albumUUID in doomedAlbums {
            await sync.markAlbumDirty(albumUUID)
        }
        try? await sync.syncAlbums()
        await reload()
    }

    func moveAlbum(_ uuid: UUID, toFolder folderUUID: UUID?) async {
        try? await store.moveAlbum(uuid, toFolder: folderUUID)
        await reload()
    }
}
