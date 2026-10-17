import Foundation

/// Loads the set of geo-tagged assets shown on the Places map.
@MainActor
@Observable
final class PlacesStore {
    private(set) var assets: [Asset] = []
    private(set) var isLoaded = false
    private let db: DatabaseActor

    init(db: DatabaseActor) {
        self.db = db
    }

    func reload() async {
        let rows = (try? await db.query("""
            SELECT * FROM assets
            WHERE latitude IS NOT NULL AND longitude IS NOT NULL
              AND is_deleted = 0 AND is_hidden = 0
            ORDER BY captured_at DESC
            """)) ?? []
        assets = rows.map(Asset.init)
        isLoaded = true
    }
}
