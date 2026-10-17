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
        case album(UUID)
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
            case .album(let uuid):
                return """
                SELECT a.* FROM assets a
                JOIN album_assets aa ON aa.asset_uuid = a.uuid
                WHERE aa.album_uuid = '\(uuid.uuidString)' AND a.is_deleted = 0
                ORDER BY aa.sort_index ASC, a.captured_at DESC
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
        assets = ((try? await db.query(filter.sql)) ?? []).map(Asset.init)
    }
}

/// Grid of a filtered asset list (non-timeline views).
struct FilteredAssetGridView: View {
    let cache: DerivativeCache
    let db: DatabaseActor
    let filter: FilteredAssetStore.Filter
    @State private var store: FilteredAssetStore?
    @State private var selection = Set<UUID>()

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
                    AssetGridView(assets: store.assets, cache: cache, selection: $selection)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            let store = FilteredAssetStore(filter: filter, db: db)
            self.store = store
            await store.reload()
        }
    }
}
