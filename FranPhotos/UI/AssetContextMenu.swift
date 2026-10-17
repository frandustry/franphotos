import SwiftUI

/// Context menu for grid cells: favorite, add-to-album, hide, move to trash.
struct AssetContextMenu: View {
    /// The full current selection (or just the clicked asset).
    let assetUUIDs: [UUID]
    @Environment(LibraryManager.self) private var manager

    var body: some View {
        Group {
            Button(String(localized: "Favorite")) {
                mutateEach { actions, uuid in
                    if let asset = try await actions.fetch(uuid) {
                        try await actions.setFavorite(uuid, !asset.isFavorite)
                    }
                }
            }
            if let albums = manager.albumsStore?.albums, !albums.isEmpty {
                Menu(String(localized: "Add to Album")) {
                    ForEach(albums.filter { $0.type == .manual }) { album in
                        Button(album.name) {
                            Task {
                                await manager.albumsStore?.add(assetUUIDs, to: album.uuid)
                            }
                        }
                    }
                }
            }
            Divider()
            Button(String(localized: "Hide")) {
                mutateEach { try await $0.setHidden($1, true) }
            }
            Button(String(localized: "Move to Trash"), role: .destructive) {
                mutateEach { try await $0.moveToTrash($1) }
            }
        }
    }

    private func mutateEach(_ mutation: @escaping (AssetActions, UUID) async throws -> Void) {
        Task {
            for uuid in assetUUIDs {
                _ = await manager.mutateAsset(uuid) { actions in
                    try await mutation(actions, uuid)
                }
            }
            await manager.timelineStore?.invalidate()
        }
    }
}
