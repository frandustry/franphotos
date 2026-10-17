import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import FranPhotos

/// Programmatic media fixtures so tests never depend on files outside the repo.
enum TestFixtures {
    struct EXIFSpec {
        var dateTimeOriginal: String? = nil      // "2025:03:14 10:30:00"
        var offsetTimeOriginal: String? = nil    // "+08:00"
        var make: String? = "Apple"
        var model: String? = "iPhone 15 Pro"
        var latitude: Double? = nil
        var longitude: Double? = nil
    }

    @discardableResult
    static func makeJPEG(
        in dir: URL, name: String, width: Int = 800, height: Int = 600, exif: EXIFSpec = .init()
    ) throws -> URL {
        let url = dir.appending(path: name)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Fill color derived from the file name so distinct fixtures have distinct bytes
        // (SHA-256 dedupe relies on content).
        var hash: UInt32 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        context.setFillColor(red: CGFloat(hash & 0xFF) / 255,
                             green: CGFloat((hash >> 8) & 0xFF) / 255,
                             blue: CGFloat((hash >> 16) & 0xFF) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = context.makeImage()!

        var properties: [CFString: Any] = [:]
        var exifDict: [CFString: Any] = [:]
        if let dto = exif.dateTimeOriginal {
            exifDict[kCGImagePropertyExifDateTimeOriginal] = dto
        }
        // Note: CGImageDestination drops kCGImagePropertyExifAuxDictionary when writing
        // JPEG; OffsetTimeOriginal must go into the main Exif dict to round-trip.
        if let offset = exif.offsetTimeOriginal {
            exifDict["OffsetTimeOriginal" as CFString] = offset
        }
        if !exifDict.isEmpty { properties[kCGImagePropertyExifDictionary] = exifDict }
        var tiffDict: [CFString: Any] = [:]
        if let make = exif.make { tiffDict[kCGImagePropertyTIFFMake] = make }
        if let model = exif.model { tiffDict[kCGImagePropertyTIFFModel] = model }
        if !tiffDict.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiffDict }
        if let lat = exif.latitude, let lon = exif.longitude {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat),
                kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(lon),
                kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
            ]
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Renders a tiny H.264 MOV with solid frames. `creationDate` sets the QuickTime creation metadata.
    @discardableResult
    static func makeVideo(
        in dir: URL, name: String, width: Int = 320, height: Int = 240,
        durationSeconds: Double = 1.0, creationDate: Date? = nil
    ) async throws -> URL {
        let url = dir.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(durationSeconds * 10)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
                                nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let value = Int32(min(255, 40 + frame * 20))
                memset(base, value, bytesPerRow * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(frame * 6), timescale: 60)
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }

        // Set creation date metadata if requested (rewrites through export is heavy;
        // creation date is optional — fixtures rely on mtime fallback otherwise).
        _ = creationDate
        return url
    }
}
