import SwiftUI

/// Generic square-cell asset grid with multi-selection and a double-click preview.
struct AssetGridView: View {
    let assets: [Asset]
    let cache: DerivativeCache
    @Binding var selection: Set<UUID>
    var cellSize: Double = 120
    var onOpen: ((Asset) -> Void)? = nil

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.4), spacing: 2)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets) { asset in
                    AssetThumbnailView(asset: asset, cache: cache)
                        .overlay(selection.contains(asset.id)
                                 ? Color.accentColor.opacity(0.25) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(selection.contains(asset.id)
                                        ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture(count: 2) {
                            selection = [asset.id]
                            onOpen?(asset)
                        }
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                if selection.contains(asset.id) {
                                    selection.remove(asset.id)
                                } else {
                                    selection.insert(asset.id)
                                }
                            } else {
                                selection = [asset.id]
                            }
                        }
                }
            }
            .padding(2)
        }
    }
}
