import SwiftUI

/// Generic square-cell asset grid with multi-selection and a double-click preview.
struct AssetGridView: View {
    let assets: [Asset]
    let cache: DerivativeCache
    @Binding var selection: Set<UUID>
    @Environment(LibraryManager.self) private var manager
    var paths: LibraryPaths? = nil
    var cellSize: Double = 120
    var onOpen: ((Asset) -> Void)? = nil
    var onPlaySlideshow: (([UUID]) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let layout = GridLayout.layout(containerWidth: proxy.size.width, target: cellSize)
            ScrollView {
                LazyVGrid(columns: layout.columns, spacing: GridLayout.spacing) {
                    ForEach(assets) { asset in
                        AssetThumbnailView(asset: asset, cache: cache, paths: paths,
                                           size: layout.cell)
                        .overlay {
                            if selection.contains(asset.id) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                        .draggable(dragPayload(for: asset))
                        .contextMenu {
                            AssetContextMenu(assetUUIDs: selection.contains(asset.id)
                                             ? Array(selection) : [asset.id],
                                             onPlaySlideshow: onPlaySlideshow)
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
                .padding(GridLayout.horizontalPadding)
            }
        }
        .onChange(of: selection) { _, newValue in
            manager.selectedAssetUUIDs = newValue
        }
    }

    /// Dragging a selected cell drags the whole selection; otherwise just the cell.
    private func dragPayload(for asset: Asset) -> String {
        let uuids = selection.contains(asset.id) ? Array(selection) : [asset.id]
        return uuids.map(\.uuidString).joined(separator: ",")
    }
}
