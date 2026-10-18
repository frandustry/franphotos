import SwiftUI

/// Cover thumbnail for a month/year card: fast path hits the derivative cache by
/// UUID; slow path fetches the asset row from the DB and renders it.
struct CoverImageView: View {
    let assetUUID: UUID?
    let db: DatabaseActor
    let cache: DerivativeCache
    var size: DerivativeSize = .thumb
    @State private var image: NSImage?

    var body: some View {
        // Flexible Color base + overlay image: the image's natural size can
        // never inflate this view's reported bounds.
        Color.secondary.opacity(0.08)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(.quaternary)
                }
            }
            .clipped()
            .task(id: assetUUID) {
                await load()
            }
    }

    private func load() async {
        guard let assetUUID else { return }
        if let quick = await cache.imageIfCached(forAssetUUID: assetUUID, size: size) {
            image = quick
            return
        }
        guard let row = try? await db.query(
            "SELECT * FROM assets WHERE uuid = ?", [.text(assetUUID.uuidString)]
        ).first else { return }
        let asset = Asset(row: row)
        image = await cache.image(for: asset, size: size)
    }
}
