import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FranPhotos

struct RenderLayerTests {
    /// Creates a solid-color JPEG fixture with the given pixel size.
    private func makeJPEG(width: Int, height: Int, in dir: URL, name: String = "fixture.jpg") throws -> URL {
        let url = dir.appending(path: name)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = context.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func downsampleRespectsMaxPixelSize() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeJPEG(width: 4000, height: 2000, in: dir)
        guard let thumb = ImageDecoder.downsampledImage(at: url, maxPixelSize: 512) else {
            Issue.record("downsample returned nil")
            return
        }
        #expect(max(thumb.width, thumb.height) <= 512)
        #expect(thumb.width > thumb.height)  // aspect preserved
    }

    @Test func pixelSizeWithoutDecoding() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeJPEG(width: 1600, height: 900, in: dir)
        let size = ImageDecoder.pixelSize(at: url)
        #expect(size?.width == 1600)
        #expect(size?.height == 900)
    }

    @Test func plainJPEGIsDetectedSDR() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeJPEG(width: 64, height: 64, in: dir)
        #expect(ImageDecoder.inferredHDRType(at: url) == .sdr)
        #expect(!ImageDecoder.hasHDRGainMap(at: url))
    }

    @Test func derivativeCacheRendersAndPersists() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let libURL = dir.appending(path: "Lib.franphotoslibrary")
        let store = try LibraryStore.create(at: libURL)
        let fixture = try makeJPEG(width: 3000, height: 2000, in: dir)
        // Place the fixture where the asset's original would live.
        let uuid = UUID()
        let rel = "originals/2024/06/\(uuid.uuidString).jpg"
        let originalDest = store.paths.url(forRelativePath: rel)
        try FileManager.default.createDirectory(
            at: originalDest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: originalDest)

        var asset = Asset(
            uuid: uuid, mediaType: .photo, capturedAt: Date(), capturedAtTZOffset: nil,
            addedAt: Date(), durationMs: nil, width: 3000, height: 2000, fileSize: 1000,
            sha256: uuid.uuidString, originalRelpath: rel, filename: "fixture.jpg",
            uti: nil, title: nil, caption: nil,
            isFavorite: false, isHidden: false, isDeleted: false, deletedAt: nil, rating: 0,
            cameraMake: nil, cameraModel: nil, lensModel: nil, iso: nil,
            aperture: nil, shutterSpeed: nil, focalLength: nil,
            latitude: nil, longitude: nil, altitude: nil,
            hdrType: .sdr, isLivePhoto: false, livePhotoVideoRelpath: nil,
            livePhotoStillTimeMs: nil, videoCodec: nil, colorSpace: nil,
            hasAudio: nil, frameRate: nil, editRecipeJSON: nil, editVersion: 0)

        let cache = DerivativeCache(paths: store.paths)
        guard let img = await cache.image(for: asset, size: .thumb) else {
            Issue.record("derivative render failed")
            return
        }
        #expect(img.size.width > 0)
        // Derivative file written to disk.
        let thumbURL = DerivativeSize.thumb.url(for: uuid, in: store.paths)
        #expect(FileManager.default.fileExists(atPath: thumbURL.path))
        // Second call succeeds (memory or disk hit) and returns an equal-size image.
        let again = await cache.image(for: asset, size: .thumb)
        #expect(again?.size == img.size)

        // Edit version bump produces a different cache key (old file cleared via invalidate).
        asset.editVersion = 1
        await cache.invalidate(uuid)
        #expect(!FileManager.default.fileExists(atPath: thumbURL.path))
        let rerendered = await cache.image(for: asset, size: .thumb)
        #expect(rerendered != nil)
        #expect(FileManager.default.fileExists(atPath: thumbURL.path))
    }
}
