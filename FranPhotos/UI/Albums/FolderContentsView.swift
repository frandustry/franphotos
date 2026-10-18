import SwiftUI

/// Folder detail: a grid of the folder's subfolders and albums, like Apple
/// Photos' folder view. Cards navigate into the album/folder on click.
struct FolderContentsView: View {
    let folderUUID: UUID
    let db: DatabaseActor
    let cache: DerivativeCache
    var onOpenAlbum: (UUID) -> Void
    var onOpenFolder: (UUID) -> Void

    @Environment(LibraryManager.self) private var manager
    @State private var counts: [UUID: Int] = [:]
    @State private var covers: [UUID: UUID] = [:]

    private var folder: AlbumFolder? {
        manager.albumsStore?.folders.first { $0.uuid == folderUUID }
    }
    private var subfolders: [AlbumFolder] {
        (manager.albumsStore?.folders ?? []).filter { $0.parentFolderUUID == folderUUID }
    }
    private var albums: [Album] {
        (manager.albumsStore?.albums ?? []).filter { $0.folderUUID == folderUUID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(folder?.name ?? "")
                    .font(.title2.bold())
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                if subfolders.isEmpty && albums.isEmpty {
                    ContentUnavailableView(
                        String(localized: "Empty Folder"),
                        systemImage: "folder",
                        description: Text("Drag albums here from the sidebar."))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 20)],
                              spacing: 20) {
                        ForEach(subfolders) { subfolder in
                            folderCard(subfolder)
                        }
                        ForEach(albums) { album in
                            albumCard(album)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .task(id: folderUUID) { await loadCardMetadata() }
        .onChange(of: manager.albumsStore?.albums.count) { _, _ in
            Task { await loadCardMetadata() }
        }
    }

    private func folderCard(_ folder: AlbumFolder) -> some View {
        let childCount = (manager.albumsStore?.albums ?? [])
            .filter { $0.folderUUID == folder.uuid }.count
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
                Image(systemName: "folder")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
            Text(folder.name).font(.headline)
            Text(String(localized: "\(childCount) items"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenFolder(folder.uuid) }
    }

    private func albumCard(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImageView(assetUUID: covers[album.uuid] ?? album.coverAssetUUID,
                           db: db, cache: cache)
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            Text(album.name).font(.headline)
            Text(String(localized: "\(counts[album.uuid] ?? 0) items"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenAlbum(album.uuid) }
    }

    /// Covers and counts are one cheap query per album, loaded once per view.
    /// Smart albums evaluate their rules (membership table is empty for them).
    private func loadCardMetadata() async {
        let store = AlbumStore(db: db)
        for album in albums {
            if album.type == .smart {
                counts[album.uuid] = (try? await store.assets(in: album.uuid))?.count ?? 0
            } else {
                counts[album.uuid] = (try? await store.assetCount(in: album.uuid)) ?? 0
            }
            if album.coverAssetUUID == nil, covers[album.uuid] == nil {
                if let assets = try? await store.assets(in: album.uuid),
                   let first = assets.first {
                    covers[album.uuid] = first.uuid
                }
            }
        }
    }
}
