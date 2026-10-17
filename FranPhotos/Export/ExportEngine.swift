import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ExportOptions: Sendable, Equatable {
    enum PhotoFormat: String, Sendable, CaseIterable {
        case original, jpeg, png, heic, tiff

        var localizedName: String {
            switch self {
            case .original: String(localized: "Original (unmodified)")
            case .jpeg: "JPEG"
            case .png: "PNG"
            case .heic: "HEIC"
            case .tiff: "TIFF"
            }
        }
    }

    enum VideoMode: String, Sendable, CaseIterable {
        case original, transcode

        var localizedName: String {
            switch self {
            case .original: String(localized: "Original (unmodified)")
            case .transcode: String(localized: "Transcode")
            }
        }
    }

    enum VideoCodec: String, Sendable, CaseIterable {
        case h264, hevc

        var localizedName: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC (H.265)"
            }
        }
    }

    enum VideoResolution: String, Sendable, CaseIterable {
        case original, uhd2160, fhd1080, hd720

        var localizedName: String {
            switch self {
            case .original: String(localized: "Original resolution")
            case .uhd2160: "4K (3840×2160)"
            case .fhd1080: "1080p (1920×1080)"
            case .hd720: "720p (1280×720)"
            }
        }
    }

    enum VideoContainer: String, Sendable, CaseIterable {
        case mp4, mov

        var localizedName: String { rawValue.uppercased() }
    }

    var photoFormat: PhotoFormat = .original
    var jpegQuality: Double = 0.9
    var videoMode: VideoMode = .original
    var videoCodec: VideoCodec = .hevc
    var videoResolution: VideoResolution = .original
    var videoContainer: VideoContainer = .mp4
    var writeXMPSidecars = true
    var includeLivePhotoVideo = true
}

struct ExportResult: Sendable {
    var exported = 0
    var failed = 0
    var cancelled = false
}

/// Exports assets to a folder. Photos: original copy or re-encode (JPEG/PNG/HEIC/TIFF,
/// edits applied). Videos: original copy or VideoToolbox-hardware-accelerated
/// transcode via AVAssetExportSession (H.264/HEVC; HEVC preserves HDR metadata).
/// Optional XMP/IPTC sidecar per item.
///
/// Cancellation: callers register live export sessions through `sessionRegistry`
/// so the UI can cancel an in-flight transcode.
final class ExportEngine: @unchecked Sendable {
    let db: DatabaseActor
    let paths: LibraryPaths

    /// Live AVAssetExportSessions keyed by asset UUID (for cancellation).
    let sessionRegistry = SessionRegistry()

    init(db: DatabaseActor, paths: LibraryPaths) {
        self.db = db
        self.paths = paths
    }

    final class SessionRegistry: @unchecked Sendable {
        private var sessions: [UUID: AVAssetExportSession] = [:]
        private let lock = NSLock()

        func register(_ uuid: UUID, _ session: AVAssetExportSession) {
            lock.lock()
            sessions[uuid] = session
            lock.unlock()
        }

        func unregister(_ uuid: UUID) {
            lock.lock()
            sessions.removeValue(forKey: uuid)
            lock.unlock()
        }

        func cancelAll() {
            lock.lock()
            let all = Array(sessions.values)
            lock.unlock()
            for session in all { session.cancelExport() }
        }
    }

    func export(
        uuids: [UUID],
        destination: URL,
        options: ExportOptions,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> ExportResult {
        var result = ExportResult()
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for (index, uuid) in uuids.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            onProgress(index, uuids.count)
            do {
                guard let row = try await db.query(
                    "SELECT * FROM assets WHERE uuid = ?", [.text(uuid.uuidString)]
                ).first else { continue }
                let asset = Asset(row: row)
                try await exportOne(asset: asset, destination: destination, options: options)
                result.exported += 1
            } catch {
                result.failed += 1
            }
        }
        onProgress(uuids.count, uuids.count)
        return result
    }

    // MARK: - Per-asset export

    private func exportOne(
        asset: Asset, destination: URL, options: ExportOptions
    ) async throws {
        let fm = FileManager.default
        let source = paths.url(forRelativePath: asset.originalRelpath)
        let stem = asset.filename.replacingOccurrences(of: ".\(source.pathExtension)", with: "")
        var producedURLs: [URL] = []

        if asset.mediaType == .photo {
            switch options.photoFormat {
            case .original:
                let dest = uniqueURL(in: destination, filename: asset.filename)
                try fm.copyItem(at: source, to: dest)
                producedURLs.append(dest)
            default:
                let ext = options.photoFormat.rawValue
                let dest = uniqueURL(in: destination, filename: "\(stem).\(ext)")
                try renderPhoto(asset: asset, to: dest,
                                format: options.photoFormat, quality: options.jpegQuality)
                producedURLs.append(dest)
            }
            // Live photo video component.
            if options.includeLivePhotoVideo, let liveRel = asset.livePhotoVideoRelpath {
                let liveSource = paths.url(forRelativePath: liveRel)
                let liveDest = uniqueURL(in: destination, filename: "\(stem).mov")
                if options.videoMode == .transcode {
                    try await transcodeVideo(source: liveSource, destination: liveDest,
                                             options: options, assetUUID: asset.uuid)
                } else {
                    try? fm.copyItem(at: liveSource, to: liveDest)
                }
                producedURLs.append(liveDest)
            }
        } else {
            // Videos.
            if options.videoMode == .transcode {
                let dest = uniqueURL(
                    in: destination,
                    filename: "\(stem).\(options.videoContainer.rawValue)")
                try await transcodeVideo(source: source, destination: dest,
                                         options: options, assetUUID: asset.uuid)
                producedURLs.append(dest)
            } else {
                let dest = uniqueURL(in: destination, filename: asset.filename)
                try fm.copyItem(at: source, to: dest)
                producedURLs.append(dest)
            }
        }

        if options.writeXMPSidecars, let first = producedURLs.first {
            let keywords = (try? await db.query("""
                SELECT k.name FROM asset_keywords ak
                JOIN keywords k ON k.uuid = ak.keyword_uuid
                WHERE ak.asset_uuid = ?
                """, [.text(asset.uuid.uuidString)]))?.compactMap { $0.text("name") } ?? []
            let xmp = XMP.Metadata(
                title: asset.title, caption: asset.caption, keywords: keywords,
                rating: asset.rating > 0 ? asset.rating : nil,
                dateCreated: asset.capturedAt,
                latitude: asset.latitude, longitude: asset.longitude)
            try? XMP.write(xmp, to: first.deletingPathExtension()
                .appendingPathExtension("xmp"))
        }
    }

    // MARK: - Photo rendering

    private func renderPhoto(asset: Asset, to dest: URL,
                             format: ExportOptions.PhotoFormat, quality: Double) throws {
        // Edited assets: start from the rendered edit derivative.
        let source = EditEngine.editDerivativeURL(asset: asset, paths: paths)
        let hdrType: HDRType
        let sourceURL: URL
        if let source {
            sourceURL = source
            hdrType = .sdr
        } else {
            sourceURL = paths.url(forRelativePath: asset.originalRelpath)
            hdrType = asset.hdrType
        }
        guard let cg = HDRCompositor.sdrImage(from: sourceURL, hdrType: hdrType,
                                              maxPixelSize: 10_000) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let uti: UTType = switch format {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .original: .jpeg  // unreachable
        }
        guard let destination = CGImageDestinationCreateWithURL(
            dest as CFURL, uti.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cg, format == .jpeg || format == .heic
                                   ? props as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: - Video transcoding (VideoToolbox via AVAssetExportSession)

    private func transcodeVideo(
        source: URL, destination: URL, options: ExportOptions, assetUUID: UUID
    ) async throws {
        let avAsset = AVURLAsset(url: source)
        let preset = await resolvePreset(codec: options.videoCodec,
                                         resolution: options.videoResolution,
                                         asset: avAsset)
        guard let session = AVAssetExportSession(asset: avAsset, presetName: preset)
        else { throw CocoaError(.featureUnsupported) }
        sessionRegistry.register(assetUUID, session)
        defer { sessionRegistry.unregister(assetUUID) }

        let fileType: AVFileType = options.videoContainer == .mp4 ? .mp4 : .mov
        try? FileManager.default.removeItem(at: destination)
        // VideoToolbox hardware encode is used automatically for H.264/HEVC on
        // Apple Silicon; HEVC presets preserve HDR (HLG/PQ/Dolby Vision) metadata.
        do {
            try await session.export(to: destination, as: fileType)
        } catch is CancellationError {
            throw CocoaError(.userCancelled)
        }
    }

    /// Picks the best *available* preset for codec + resolution, degrading gracefully.
    private func resolvePreset(
        codec: ExportOptions.VideoCodec,
        resolution: ExportOptions.VideoResolution,
        asset: AVURLAsset
    ) async -> String {
        let preferred: [String]
        switch (codec, resolution) {
        case (.hevc, .original): preferred = [AVAssetExportPresetHEVCHighestQuality]
        case (.hevc, .uhd2160): preferred = [AVAssetExportPresetHEVC3840x2160,
                                             AVAssetExportPresetHEVCHighestQuality]
        case (.hevc, .fhd1080): preferred = [AVAssetExportPresetHEVC1920x1080,
                                             AVAssetExportPresetHEVCHighestQuality]
        case (.hevc, .hd720): preferred = [AVAssetExportPresetHEVC1920x1080,
                                           AVAssetExportPresetHEVCHighestQuality]
        case (.h264, .original): preferred = [AVAssetExportPresetHighestQuality]
        case (.h264, .uhd2160): preferred = [AVAssetExportPreset3840x2160,
                                             AVAssetExportPresetHighestQuality]
        case (.h264, .fhd1080): preferred = [AVAssetExportPreset1920x1080,
                                             AVAssetExportPresetHighestQuality]
        case (.h264, .hd720): preferred = [AVAssetExportPreset1280x720,
                                           AVAssetExportPresetHighestQuality]
        }
        let available = await AVAssetExportSession.exportPresets(compatibleWith: asset)
        return preferred.first { available.contains($0) }
            ?? (codec == .hevc ? AVAssetExportPresetHEVCHighestQuality
                               : AVAssetExportPresetHighestQuality)
    }

    // MARK: - Helpers

    private func uniqueURL(in dir: URL, filename: String) -> URL {
        var url = dir.appending(path: filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            url = dir.appending(path: "\(stem)-\(counter).\(ext)")
            counter += 1
        }
        return url
    }
}
