import SwiftUI

/// Generic square-cell asset grid with multi-selection and a double-click preview.
struct AssetGridView: View {
    let assets: [Asset]
    let cache: DerivativeCache
    @Binding var selection: Set<UUID>
    var paths: LibraryPaths? = nil
    var cellSize: Double = 120
    var onOpen: ((Asset) -> Void)? = nil

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.4), spacing: 2)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets) { asset in
                    AssetThumbnailView(asset: asset, cache: cache, paths: paths)
                        .overlay(selection.contains(asset.id)
                                 ? Color.accentColor.opacity(0.25) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(selection.contains(asset.id)
                                        ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                        .draggable(dragPayload(for: asset))
                        .contextMenu {
                            AssetContextMenu(assetUUIDs: selection.contains(asset.id)
                                             ? Array(selection) : [asset.id])
                        }
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

    /// Dragging a selected cell drags the whole selection; otherwise just the cell.
    private func dragPayload(for asset: Asset) -> String {
        let uuids = selection.contains(asset.id) ? Array(selection) : [asset.id]
        return uuids.map(\.uuidString).joined(separator: ",")
    }
}
