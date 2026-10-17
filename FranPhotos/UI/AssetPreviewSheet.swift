import SwiftUI

/// Quick preview surface (double-click a grid cell). Step 10 adds video playback;
/// step 13 turns this into the full detail browser with info panel and editing.
struct AssetPreviewSheet: View {
    let asset: Asset
    @Environment(LibraryManager.self) private var manager

    var body: some View {
        Group {
            if let paths = manager.library?.paths {
                MediaStageView(asset: asset, paths: paths,
                               autoplay: asset.mediaType == .video,
                               muted: false,
                               showsControls: true)
            }
        }
        .frame(minWidth: 720, minHeight: 540)
    }
}
