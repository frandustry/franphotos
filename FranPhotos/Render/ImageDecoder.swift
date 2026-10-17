import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO-based decoding helpers. All static, all synchronous — call from
/// background contexts (the derivative cache / import pipeline do so).
enum ImageDecoder {
    // MARK: - Downsampling

    /// Decodes a downsampled image: never allocates more pixels than requested.
    /// Honors EXIF orientation. `maxPixelSize` is the longest edge in pixels.
    static func downsampledImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Full-resolution decode with EXIF orientation applied.
    static func fullImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel dimensions without decoding the image.
    static func pixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    // MARK: - HDR detection

    /// True when the image carries an ISO 21496-1 / Apple HDR gain map.
    static func hasHDRGainMap(at url: URL) -> Bool {
        gainMapImage(at: url) != nil
    }

    /// Decodes the auxiliary HDR gain map image, if present.
    static func gainMapImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [CFString: Any],
              let data = info[kCGImageAuxiliaryDataInfoData] as? Data
        else { return nil }
        guard let gainSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(gainSource, 0, nil)
    }

    /// Infers the HDR flavor of a still image: gain map > HLG > PQ > SDR.
    /// The color space probe uses a tiny 8px decode, so this is cheap.
    static func inferredHDRType(at url: URL) -> HDRType {
        if hasHDRGainMap(at: url) { return .gainmap }
        guard let probe = downsampledImage(at: url, maxPixelSize: 8),
              let name = probe.colorSpace?.name as? String
        else { return .sdr }
        let lowered = name.lowercased()
        if lowered.contains("hlg") || lowered.contains("2100") && lowered.contains("hl") {
            return .hlg
        }
        if lowered.contains("pq") || lowered.contains("perceptual") {
            return .pq
        }
        return .sdr
    }

    // MARK: - Metadata

    /// Raw ImageIO property dictionaries (EXIF, TIFF, GPS, IPTC…).
    static func properties(at url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    /// Writes a CGImage as JPEG (SDR), returning the destination URL.
    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationEmbedThumbnail: false,
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
