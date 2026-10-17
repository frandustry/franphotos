import Foundation
import SwiftUI

/// A directly-queried (non-timeline) asset list: videos, favorites, live photos,
/// search results, album contents. Reloaded explicitly after mutations.
@MainActor
@Observable
final class FilteredAssetStore {
    enum Kind {
        case videos
        case livePhotos
        case favorites
        case hidden
        case recentlyDeleted
        case album(UUID)
        case person(UUID)
        case searchResults([UUID])
    }

    struct Filter {
        let kind: Kind

        var sql: String {
            switch kind {
            case .videos:
                return "SELECT * FROM assets WHERE media_type = 'video' AND is_deleted = 0 AND is_hidden = 0 ORDER BY captured_at DESC"
            case .livePhotos:
                return "SELECT * FROM assets WHERE is_live_photo = 1 AND is_deleted = 0 AND is_hidden = 0 ORDER BY captured_at DESC"
            case .favorites:
                return "SELECT * FROM assets WHERE is_favorite = 1 AND is_deleted = 0 AND is_hidden = 0 ORDER BY captured_at DESC"
            case .hidden:
                return "SELECT * FROM assets WHERE is_hidden = 1 AND is_deleted = 0 ORDER BY captured_at DESC"
            case .recentlyDeleted:
                return "SELECT * FROM assets WHERE is_deleted = 1 ORDER BY deleted_at DESC"
            case .album(let uuid):
                return """
                SELECT a.* FROM assets a
                JOIN album_assets aa ON aa.asset_uuid = a.uuid
                WHERE aa.album_uuid = '\(uuid.uuidString)' AND a.is_deleted = 0
                ORDER BY aa.sort_index ASC, a.captured_at DESC
                """
            case .person(let uuid):
                return """
                SELECT DISTINCT a.* FROM assets a
                JOIN faces f ON f.asset_uuid = a.uuid
                WHERE f.person_uuid = '\(uuid.uuidString)' AND a.is_deleted = 0
                ORDER BY a.captured_at DESC
                """
            case .searchResults(let uuids):
                let list = uuids.map { "'\($0.uuidString)'" }.joined(separator: ",")
                return "SELECT * FROM assets WHERE uuid IN (\(list)) AND is_deleted = 0 ORDER BY captured_at DESC"
            }
        }
    }

    private(set) var assets: [Asset] = []
    let filter: Filter
    private let db: DatabaseActor

    init(filter: Filter, db: DatabaseActor) {
        self.filter = filter
        self.db = db
    }

    func reload() async {
        // Albums route through AlbumStore so smart-album rules are evaluated.
        if case .album(let uuid) = filter.kind {
            assets = (try? await AlbumStore(db: db).assets(in: uuid)) ?? []
            return
        }
        assets = ((try? await db.query(filter.sql)) ?? []).map(Asset.init)
    }
}

/// Grid of a filtered asset list (non-timeline views).
struct FilteredAssetGridView: View {
    let cache: DerivativeCache
    let db: DatabaseActor
    let paths: LibraryPaths
    let filter: FilteredAssetStore.Filter
    @State private var store: FilteredAssetStore?
    @State private var selection = Set<UUID>()
    @State private var previewAsset: Asset?
    @State private var slideshowAssets: [Asset]?

    var body: some View {
        Group {
            if let store {
                if store.assets.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Items"),
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Items matching this view will appear here.")
                    )
                } else {
                    AssetGridView(assets: store.assets, cache: cache, selection: $selection,
                                  paths: paths, onOpen: { previewAsset = $0 },
                                  onPlaySlideshow: { uuids in
                                      slideshowAssets = store.assets.filter { uuids.contains($0.id) }
                                  })
                }
            } else {
                ProgressView()
            }
        }
        .overlay {
            if let slideshowAssets {
                SlideshowView(assets: slideshowAssets, paths: paths,
                              onClose: { self.slideshowAssets = nil })
                .transition(.opacity)
            }
            if let previewAsset, let store {
                DetailView(initialAsset: previewAsset, paths: paths,
                           nextAsset: { asset in
                               guard let idx = store.assets.firstIndex(where: { $0.id == asset.id })
                               else { return nil }
                               return store.assets[safe: idx + 1]
                           },
                           previousAsset: { asset in
                               guard let idx = store.assets.firstIndex(where: { $0.id == asset.id })
                               else { return nil }
                               return store.assets[safe: idx - 1]
                           },
                           onClose: { self.previewAsset = nil })
                .transition(.opacity)
            }
        }
        .task {
            let store = FilteredAssetStore(filter: filter, db: db)
            self.store = store
            await store.reload()
        }
    }
}
