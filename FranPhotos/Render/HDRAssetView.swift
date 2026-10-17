import CoreImage
import Foundation
import SwiftUI

/// Detail-view surface for a photo asset: decodes the original (capped for
/// interactivity), detects gain maps, and feeds `HDRImageView` a composited
/// image at whatever headroom the current display offers.
struct HDRAssetView: View {
    let asset: Asset
    let paths: LibraryPaths
    /// Maximum decoded pixel dimension (longest edge). Full zoom-to-100% is a
    /// later refinement; this keeps memory bounded for 48MP+ sources.
    var maxDecodePixels: Int = 8000

    @State private var base: CIImage?
    @State private var gainMap: CIImage?

    var body: some View {
        HDRImageView(imageProvider: { headroom in
            guard let base else { return nil }
            return HDRCompositor.composited(base: base, gainMap: gainMap, headroom: headroom)
        }, contentVersion: asset.editVersion)
        .background(Color.black)
        .task(id: asset.uuid) {
            await load()
        }
    }

    private func load() async {
        let url = paths.url(forRelativePath: asset.originalRelpath)
        let decoded = await Task.detached(priority: .userInitiated) { () -> (CIImage?, CIImage?) in
            guard let cg = ImageDecoder.downsampledImage(at: url, maxPixelSize: maxDecodePixels)
            else { return (nil, nil) }
            var gain: CIImage?
            if asset.hdrType == .gainmap,
               let gainCG = ImageDecoder.gainMapImage(at: url) {
                gain = CIImage(cgImage: gainCG)
            }
            return (CIImage(cgImage: cg), gain)
        }.value
        base = decoded.0
        gainMap = decoded.1
    }
}
