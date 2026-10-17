import AppKit
import CoreImage
import CoreGraphics
import Foundation

/// Composites HDR sources (gain map / HLG / PQ) for display or SDR export.
///
/// One code path serves both cases: `headroom = 1.0` produces tone-mapped SDR
/// (grid thumbnails, SDR displays, JPEG derivatives); `headroom > 1` produces
/// extended-range pixels for EDR rendering on XDR displays (see HDRImageView).
enum HDRCompositor {
    /// Shared CIContext backed by Metal. Creating CIContexts is expensive — reuse.
    static let sharedContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .name: "FranPhotos.HDRCompositor",
            ])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// Returns the image with its HDR gain map applied at the given headroom.
    /// `headroom` is relative to SDR white (1.0 = SDR). Non-gain-map HDR sources
    /// (HLG/PQ) are returned unchanged — their color space drives interpretation.
    static func composited(base: CIImage, gainMap: CIImage?, headroom: Float) -> CIImage {
        guard let gainMap else { return base }
        let clamped = max(1.0, min(headroom, 8.0))
        return base.applyingGainMap(gainMap, headroom: clamped)
    }

    /// Renders a still image to a tone-mapped SDR CGImage, applying the gain map
    /// at headroom 1 when present so SDR output keeps the intended look.
    static func sdrImage(from url: URL, hdrType: HDRType, maxPixelSize: Int) -> CGImage? {
        guard let baseCG = ImageDecoder.downsampledImage(at: url, maxPixelSize: maxPixelSize)
        else { return nil }
        guard hdrType == .gainmap,
              let gainCG = ImageDecoder.gainMapImage(at: url)
        else { return baseCG }
        let base = CIImage(cgImage: baseCG)
        let gain = CIImage(cgImage: gainCG)
        let composited = composited(base: base, gainMap: gain, headroom: 1.0)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? baseCG.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        return sharedContext.createCGImage(
            composited, from: base.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// Current display EDR headroom for the given screen (1.0 = no EDR).
    /// Reads `NSScreen.maximumExtendedDynamicRangeColorComponentValue`.
    @MainActor
    static func edrHeadroom(for screen: NSScreen?) -> Float {
        guard let screen else { return 1.0 }
        return Float(max(1.0, screen.maximumExtendedDynamicRangeColorComponentValue))
    }
}
