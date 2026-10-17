import Foundation

struct ExportOptions: Sendable, Equatable {
    enum Mode: String, Sendable, CaseIterable {
        case original
        case jpeg  // rendered with edits, tone-mapped SDR

        var localizedName: String {
            switch self {
            case .original: String(localized: "Original (unmodified)")
            case .jpeg: String(localized: "JPEG (with edits applied)")
            }
        }
    }

    var mode: Mode = .original
    var includeLivePhotoVideo = true
}

struct ExportResult: Sendable {
    var exported = 0
    var failed = 0
}

/// Exports assets to a folder. Originals keep full fidelity (including HDR gain
/// maps and live-photo video components); JPEG mode renders edits and tone-maps.
enum ExportEngine {
    static func export(
        uuids: [UUID],
        db: DatabaseActor,
        paths: LibraryPaths,
        destination: URL,
        options: ExportOptions,
        onProgress: @Sendable (Int, Int) -> Void
    ) async -> ExportResult {
        var result = ExportResult()
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for (index, uuid) in uuids.enumerated() {
            if Task.isCancelled { break }
            onProgress(index, uuids.count)
            do {
                guard let row = try await db.query(
                    "SELECT * FROM assets WHERE uuid = ?", [.text(uuid.uuidString)]
                ).first else { continue }
                let asset = Asset(row: row)
                try exportOne(asset: asset, paths: paths, destination: destination,
                              options: options)
                result.exported += 1
            } catch {
                result.failed += 1
            }
        }
        onProgress(uuids.count, uuids.count)
        return result
    }

    private static func exportOne(
        asset: Asset, paths: LibraryPaths, destination: URL, options: ExportOptions
    ) throws {
        let fm = FileManager.default
        let source = paths.url(forRelativePath: asset.originalRelpath)

        switch options.mode {
        case .original:
            let dest = uniqueURL(in: destination, filename: asset.filename)
            try fm.copyItem(at: source, to: dest)
            // Live photo: export the video component alongside.
            if options.includeLivePhotoVideo, let liveRel = asset.livePhotoVideoRelpath {
                let liveSource = paths.url(forRelativePath: liveRel)
                let liveName = asset.filename.replacingOccurrences(
                    of: ".\(source.pathExtension)", with: "") + "." + liveSource.pathExtension
                let liveDest = uniqueURL(in: destination, filename: liveName)
                try? fm.copyItem(at: liveSource, to: liveDest)
            }
        case .jpeg:
            let baseName = asset.filename.replacingOccurrences(
                of: ".\(source.pathExtension)", with: "") + ".jpg"
            let dest = uniqueURL(in: destination, filename: baseName)
            if asset.mediaType == .video {
                // Export the poster frame for videos in JPEG mode.
                guard let cg = ImageDecoder.downsampledImage(at: source, maxPixelSize: 8000) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard ImageDecoder.writeJPEG(cg, to: dest, quality: 0.9) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return
            }
            // Edited assets: the edit derivative already has edits applied.
            if let edited = EditEngine.editDerivativeURL(asset: asset, paths: paths) {
                try fm.copyItem(at: edited, to: dest)
                return
            }
            guard let cg = HDRCompositor.sdrImage(from: source, hdrType: asset.hdrType,
                                                  maxPixelSize: 10_000) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard ImageDecoder.writeJPEG(cg, to: dest, quality: 0.92) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func uniqueURL(in dir: URL, filename: String) -> URL {
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
