import AppKit
import AVFoundation
import CoreGraphics
import Foundation

/// NSCache is documented thread-safe ("you can add, remove, and query items from
/// different threads without locking") but is not annotated Sendable. Wrap it.
final class SendableImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()

    var totalCostLimit: Int {
        get { cache.totalCostLimit }
        set { cache.totalCostLimit = newValue }
    }

    func object(forKey key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func setObject(_ image: NSImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
    func removeObject(forKey key: String) { cache.removeObject(forKey: key as NSString) }
    func removeAllObjects() { cache.removeAllObjects() }
}

/// Three-tier derivative cache: NSCache (memory) → library `derivatives/` (disk)
/// → decode original (slow path, regenerates and stores the derivative).
///
/// Keyed by asset UUID *and* edit version, so edits invalidate the grid
/// automatically by bumping `editVersion` in the database.
actor DerivativeCache {
    private let paths: LibraryPaths
    private let memory = SendableImageCache()
    /// In-flight generations, so concurrent requests for the same key share one decode.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init(paths: LibraryPaths, memoryLimitBytes: Int = 256 * 1024 * 1024) {
        self.paths = paths
        memory.totalCostLimit = memoryLimitBytes
    }

    private func key(for asset: Asset, size: DerivativeSize) -> String {
        "\(asset.uuid.uuidString)-\(size.rawValue)-e\(asset.editVersion)"
    }

    func image(for asset: Asset, size: DerivativeSize) async -> NSImage? {
        let key = key(for: asset, size: size)
        if let hit = memory.object(forKey: key) { return hit }

        if let task = inFlight[key] { return await task.value }

        let task = Task<NSImage?, Never> { [paths, memory] in
            // Disk hit?
            let fileURL = size.url(for: asset.uuid, in: paths)
            if let disk = NSImage(contentsOf: fileURL) {
                memory.setObject(disk, forKey: key, cost: disk.cgImageCostEstimate)
                return disk
            }
            // Slow path: render from the original.
            guard let rendered = await Self.render(asset: asset, size: size, paths: paths) else {
                return nil
            }
            let image = NSImage(cgImage: rendered,
                                size: NSSize(width: rendered.width, height: rendered.height))
            memory.setObject(image, forKey: key, cost: image.cgImageCostEstimate)
            return image
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Drops memory entries and on-disk derivatives for an asset (after edits).
    func invalidate(_ uuid: UUID) {
        for size in DerivativeSize.allCases {
            for editVersion in 0...64 {  // bounded sweep; cheap since NSCache
                memory.removeObject(forKey: "\(uuid.uuidString)-\(size.rawValue)-e\(editVersion)")
            }
            try? FileManager.default.removeItem(at: size.url(for: uuid, in: paths))
        }
    }

    /// Removes every derivative (library maintenance / reclaim disk space).
    func invalidateAll() {
        memory.removeAllObjects()
        for size in DerivativeSize.allCases {
            let dir = size == .thumb ? paths.thumbsDirectory : paths.screenDirectory
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Rendering

    private static func render(asset: Asset, size: DerivativeSize, paths: LibraryPaths) async -> CGImage? {
        let scale = Int(await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 })
        let maxPixel = size.basePixels * max(scale, 1)
        let cgImage: CGImage?
        if asset.mediaType == .video {
            cgImage = await videoPoster(asset: asset, paths: paths, maxPixel: maxPixel)
        } else {
            let original = paths.url(forRelativePath: asset.originalRelpath)
            cgImage = HDRCompositor.sdrImage(from: original, hdrType: asset.hdrType, maxPixelSize: maxPixel)
        }
        guard let cgImage else { return nil }
        let dest = size.url(for: asset.uuid, in: paths)
        ImageDecoder.writeJPEG(cgImage, to: dest, quality: size.jpegQuality)
        return cgImage
    }

    /// Poster frame for videos (and the video component of live photos).
    private static func videoPoster(asset: Asset, paths: LibraryPaths, maxPixel: Int) async -> CGImage? {
        let rel = asset.isLivePhoto ? (asset.livePhotoVideoRelpath ?? asset.originalRelpath) : asset.originalRelpath
        let url = paths.url(forRelativePath: rel)
        let avAsset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let time: CMTime
        if let stillMs = asset.livePhotoStillTimeMs {
            time = CMTime(value: CMTimeValue(stillMs), timescale: 1000)
        } else {
            time = CMTime(value: 0, timescale: 600)
        }
        return try? await generator.image(at: time).image
    }
}

private extension NSImage {
    /// Rough byte cost for NSCache eviction (width × height × 4).
    var cgImageCostEstimate: Int {
        guard let rep = representations.first else { return 1_000_000 }
        return Int(rep.pixelsWide) * Int(rep.pixelsHigh) * 4
    }
}
