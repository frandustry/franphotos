import SwiftUI

/// Sidebar rows for the My Albums tree: albums and (nested) folders.
/// Extracted as concrete view structs because a recursive @ViewBuilder
/// function cannot have an opaque `some View` return type.

/// Payload prefix for album drags so folder drops can tell "file this album"
/// apart from grid asset drags (comma-separated asset UUIDs).
enum SidebarDrag {
    static let albumPrefix = "franphotos-album:"

    static func albumPayload(_ uuid: UUID) -> String { albumPrefix + uuid.uuidString }

    static func albumUUIDs(from payloads: [String]) -> [UUID] {
        payloads.compactMap { payload in
            guard payload.hasPrefix(albumPrefix) else { return nil }
            return UUID(uuidString: String(payload.dropFirst(albumPrefix.count)))
        }
    }

    static func assetUUIDs(from payloads: [String]) -> [UUID] {
        payloads.flatMap { $0.split(separator: ",") }
            .compactMap { UUID(uuidString: String($0)) }
    }
}

/// One album row: selectable, draggable (to file it into a folder), accepts
/// asset drops from grids, context menu for folder removal / delete.
struct AlbumSidebarRow: View {
    let album: Album
    let depth: Int
    @Environment(LibraryManager.self) private var manager

    var body: some View {
        Label(album.name,
              systemImage: album.type == .smart ? "gearshape" : "rectangle.stack")
            .padding(.leading, depth == 0 ? 0 : CGFloat(depth * 14 + 10))
            .tag(SidebarItem.album(album.uuid))
            .draggable(SidebarDrag.albumPayload(album.uuid))
            .dropDestination(for: String.self) { payloads, _ in
                let uuids = SidebarDrag.assetUUIDs(from: payloads)
                guard !uuids.isEmpty else { return false }
                Task { await manager.albumsStore?.add(uuids, to: album.uuid) }
                return true
            }
            .contextMenu {
                if album.folderUUID != nil {
                    Button(String(localized: "Remove from Folder")) {
                        Task { await manager.albumsStore?.moveAlbum(album.uuid, toFolder: nil) }
                    }
                }
                Button(String(localized: "Delete Album"), role: .destructive) {
                    Task { await manager.albumsStore?.delete(album.uuid) }
                }
            }
    }
}

/// One folder row plus, when expanded, its child rows (recursive — a concrete
/// View type may reference itself). Selecting it shows FolderContentsView;
/// the chevron toggles expansion independently of selection.
struct FolderSidebarRow: View {
    let folder: AlbumFolder
    let depth: Int
    let folders: [AlbumFolder]
    let albums: [Album]
    @Binding var expandedFolders: Set<UUID>
    var onNewAlbum: (UUID) -> Void
    var onNewSubfolder: (UUID) -> Void
    var onRename: (AlbumFolder) -> Void
    var onDelete: (AlbumFolder) -> Void

    @Environment(LibraryManager.self) private var manager

    private var isExpanded: Bool { expandedFolders.contains(folder.uuid) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isExpanded {
                        expandedFolders.remove(folder.uuid)
                    } else {
                        expandedFolders.insert(folder.uuid)
                    }
                }
            Label(folder.name, systemImage: "folder")
        }
        .padding(.leading, CGFloat(depth * 14))
        .tag(SidebarItem.folder(folder.uuid))
        .dropDestination(for: String.self) { payloads, _ in
            let albumIDs = SidebarDrag.albumUUIDs(from: payloads)
            guard !albumIDs.isEmpty else { return false }
            Task {
                for id in albumIDs {
                    await manager.albumsStore?.moveAlbum(id, toFolder: folder.uuid)
                }
            }
            return true
        }
        .contextMenu {
            Button(String(localized: "New Album")) { onNewAlbum(folder.uuid) }
            Button(String(localized: "New Subfolder")) { onNewSubfolder(folder.uuid) }
            Divider()
            Button(String(localized: "Rename Folder…")) { onRename(folder) }
            Button(String(localized: "Delete Folder"), role: .destructive) {
                onDelete(folder)
            }
        }
        if isExpanded {
            ForEach(folders.filter { $0.parentFolderUUID == folder.uuid }) { subfolder in
                FolderSidebarRow(folder: subfolder, depth: depth + 1,
                                 folders: folders, albums: albums,
                                 expandedFolders: $expandedFolders,
                                 onNewAlbum: onNewAlbum, onNewSubfolder: onNewSubfolder,
                                 onRename: onRename, onDelete: onDelete)
            }
            ForEach(albums.filter { $0.folderUUID == folder.uuid }) { album in
                AlbumSidebarRow(album: album, depth: depth + 1)
            }
        }
    }
}
