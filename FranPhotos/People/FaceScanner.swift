import CoreGraphics
import Foundation
import Vision

/// Vision-based face detection. Runs off-main in the scan pipeline.
/// Face rectangles are Vision-normalized (origin bottom-left, 0…1).
enum FaceScanner {
    struct DetectedRect: Sendable, Equatable {
        var centerX: Double
        var centerY: Double
        var size: Double  // relative to min(image width, height)
    }

    static func detect(in imageURL: URL) -> [DetectedRect] {
        guard let image = ImageDecoder.downsampledImage(at: imageURL, maxPixelSize: 2048)
        else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard let _ = try? handler.perform([request]) else { return [] }
        let minDimension = Double(min(image.width, image.height))
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox  // normalized to image
            return DetectedRect(
                centerX: box.midX,
                centerY: box.midY,
                size: Double(box.width * CGFloat(image.width)) / minDimension
            )
        }
    }

    /// Crops a square around the face for the people UI.
    static func faceThumbnail(
        from imageURL: URL, centerX: Double, centerY: Double, size: Double, maxPixels: Int = 256
    ) -> CGImage? {
        guard let image = ImageDecoder.downsampledImage(at: imageURL, maxPixelSize: 1024)
        else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let minDim = min(w, h)
        let side = CGFloat(size) * minDim * 1.4  // padding around the face
        // Vision origin is bottom-left; CGImage crops are top-left.
        let rect = CGRect(
            x: CGFloat(centerX) * w - side / 2,
            y: (1 - CGFloat(centerY)) * h - side / 2,
            width: side, height: side
        ).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width > 4, rect.height > 4,
              let cropped = image.cropping(to: rect)
        else { return nil }
        // Downscale to maxPixels.
        let scale = min(1, CGFloat(maxPixels) / max(rect.width, rect.height))
        let outW = Int(rect.width * scale), outH = Int(rect.height * scale)
        guard let context = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return cropped }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return context.makeImage()
    }
}
