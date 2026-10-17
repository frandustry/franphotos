import CryptoKit
import Foundation

struct ImportProgress: Sendable, Equatable {
    enum Phase: String, Sendable { case scanning, importing, finished }
    var phase: Phase = .scanning
    var total: Int = 0
    var completed: Int = 0
    var failed: Int = 0
    var duplicates: Int = 0
    var currentFilename: String?

    var fraction: Double {
        total > 0 ? Double(completed + failed + duplicates) / Double(total) : 0
    }
}

struct ImportOutcome: Sendable {
    var importedUUIDs: [UUID] = []
    var duplicateCount = 0
    var failures: [Failure] = []

    struct Failure: Sendable, Equatable {
        var filename: String
        var message: String
    }
}

/// Copies media into the library bundle, extracts metadata, dedupes by SHA-256,
/// inserts rows, and pairs Live Photos. All media becomes an *entity copy* in
/// `originals/YYYY/MM/` — the library never references external files.
final class ImportEngine: @unchecked Sendable {
    let library: LibraryStore
    let db: DatabaseActor

    init(library: LibraryStore, db: DatabaseActor) {
        self.library = library
        self.db = db
    }

    // MARK: - Public API

    /// Imports files/folders (folders are scanned recursively). Safe to call from
    /// any context; progress is reported via `onProgress` (already on the main actor).
    func importFiles(
        _ inputs: [URL],
        onProgress: @escaping @MainActor @Sendable (ImportProgress) -> Void
    ) async -> ImportOutcome {
        var progress = ImportProgress()
        await onProgress(progress)

        let files = expandInputs(inputs)
        let classified = files.compactMap { url -> (URL, MediaType)? in
            MediaClassifier.mediaType(for: url).map { (url, $0) }
        }
        let photos = classified.filter { $0.1 == .photo }.map(\.0).sorted { $0.path < $1.path }
        let videos = classified.filter { $0.1 == .video }.map(\.0).sorted { $0.path < $1.path }

        var durationCache: [URL: Int] = [:]
        let pairing = await LivePhotoPairer.plan(photos: photos, videos: videos) { url in
            if let cached = durationCache[url] { return cached }
            let meta = await MetadataExtractor.video(from: url)
            durationCache[url] = meta.durationMs
            return meta.durationMs > 0 ? meta.durationMs : nil
        }

        progress.phase = .importing
        progress.total = pairing.lonePhotos.count + pairing.loneVideos.count + pairing.pairs.count
        await onProgress(progress)

        var outcome = ImportOutcome()
        // Process serially for predictable disk IO; libraries are IO-bound here.
        for (photo, video) in pairing.pairs.sorted(by: { $0.key.path < $1.key.path }) {
            if Task.isCancelled { break }
            await importOne(photo: photo, liveVideo: video, progress: &progress,
                            outcome: &outcome, onProgress: onProgress)
        }
        for photo in pairing.lonePhotos where !Task.isCancelled {
            await importOne(photo: photo, liveVideo: nil, progress: &progress,
                            outcome: &outcome, onProgress: onProgress)
        }
        for video in pairing.loneVideos where !Task.isCancelled {
            await importOne(video: video, progress: &progress, outcome: &outcome,
                            onProgress: onProgress)
        }

        progress.phase = .finished
        await onProgress(progress)
        return outcome
    }

    // MARK: - Pipeline

    private func importOne(
        photo: URL,
        liveVideo: URL?,
        progress: inout ImportProgress,
        outcome: inout ImportOutcome,
        onProgress: @escaping @MainActor @Sendable (ImportProgress) -> Void
    ) async {
        await processPhoto(photo, liveVideo: liveVideo, progress: &progress, outcome: &outcome)
        await onProgress(progress)
    }

    private func importOne(
        video: URL,
        progress: inout ImportProgress,
        outcome: inout ImportOutcome,
        onProgress: @escaping @MainActor @Sendable (ImportProgress) -> Void
    ) async {
        await processVideo(video, progress: &progress, outcome: &outcome)
        await onProgress(progress)
    }

    private func processPhoto(
        _ url: URL,
        liveVideo: URL?,
        progress: inout ImportProgress,
        outcome: inout ImportOutcome
    ) async {
        progress.currentFilename = url.lastPathComponent
        do {
            let hash = try sha256(of: url)
            if try await isDuplicate(hash) {
                progress.duplicates += 1
                outcome.duplicateCount += 1
                return
            }
            let photoMeta = MetadataExtractor.photo(from: url)
            var liveStillMs: Int?
            var liveDurationMs: Int?
            if let liveVideo {
                let vm = await MetadataExtractor.video(from: liveVideo)
                liveStillMs = vm.stillImageTimeMs
                liveDurationMs = vm.durationMs
            }

            let uuid = UUID()
            let capturedAt = photoMeta.capturedAt ?? fileModificationDate(url)
            let ext = url.pathExtension
            let rel = LibraryPaths.originalRelativePath(uuid: uuid, capturedAt: capturedAt, fileExtension: ext)
            let dest = library.paths.url(forRelativePath: rel)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)

            var liveRel: String?
            if let liveVideo {
                let vrel = LibraryPaths.originalRelativePath(
                    uuid: uuid, capturedAt: capturedAt, fileExtension: liveVideo.pathExtension)
                let vdest = library.paths.url(forRelativePath: vrel)
                try FileManager.default.copyItem(at: liveVideo, to: vdest)
                liveRel = vrel
            }

            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            let asset = Asset(
                uuid: uuid, mediaType: .photo,
                capturedAt: capturedAt, capturedAtTZOffset: photoMeta.tzOffsetSeconds,
                addedAt: Date(), durationMs: liveDurationMs,
                width: photoMeta.pixelWidth, height: photoMeta.pixelHeight,
                fileSize: size, sha256: hash, originalRelpath: rel,
                filename: url.lastPathComponent,
                uti: utiString(for: url),
                title: photoMeta.title, caption: photoMeta.caption,
                isFavorite: false, isHidden: false, isDeleted: false, deletedAt: nil, rating: 0,
                cameraMake: photoMeta.cameraMake, cameraModel: photoMeta.cameraModel,
                lensModel: photoMeta.lensModel, iso: photoMeta.iso,
                aperture: photoMeta.aperture, shutterSpeed: photoMeta.shutterSpeed,
                focalLength: photoMeta.focalLength,
                latitude: photoMeta.latitude, longitude: photoMeta.longitude,
                altitude: photoMeta.altitude,
                hdrType: photoMeta.hdrType,
                isLivePhoto: liveVideo != nil,
                livePhotoVideoRelpath: liveRel,
                livePhotoStillTimeMs: liveStillMs,
                videoCodec: nil, colorSpace: nil, hasAudio: nil, frameRate: nil,
                editRecipeJSON: nil, editVersion: 0
            )
            try await db.execute(Asset.insertSQL, asset.insertBindings)
            progress.completed += 1
            outcome.importedUUIDs.append(uuid)
        } catch {
            progress.failed += 1
            outcome.failures.append(.init(filename: url.lastPathComponent,
                                          message: error.localizedDescription))
        }
    }

    private func processVideo(
        _ url: URL,
        progress: inout ImportProgress,
        outcome: inout ImportOutcome
    ) async {
        progress.currentFilename = url.lastPathComponent
        do {
            let hash = try sha256(of: url)
            if try await isDuplicate(hash) {
                progress.duplicates += 1
                outcome.duplicateCount += 1
                return
            }
            let meta = await MetadataExtractor.video(from: url)
            let uuid = UUID()
            let capturedAt = meta.capturedAt ?? fileModificationDate(url)
            let rel = LibraryPaths.originalRelativePath(uuid: uuid, capturedAt: capturedAt,
                                                        fileExtension: url.pathExtension)
            let dest = library.paths.url(forRelativePath: rel)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0

            let asset = Asset(
                uuid: uuid, mediaType: .video,
                capturedAt: capturedAt, capturedAtTZOffset: nil,
                addedAt: Date(), durationMs: meta.durationMs,
                width: meta.pixelWidth, height: meta.pixelHeight,
                fileSize: size, sha256: hash, originalRelpath: rel,
                filename: url.lastPathComponent,
                uti: utiString(for: url),
                title: nil, caption: nil,
                isFavorite: false, isHidden: false, isDeleted: false, deletedAt: nil, rating: 0,
                cameraMake: nil, cameraModel: nil, lensModel: nil, iso: nil,
                aperture: nil, shutterSpeed: nil, focalLength: nil,
                latitude: nil, longitude: nil, altitude: nil,
                hdrType: meta.hdrType,
                isLivePhoto: false, livePhotoVideoRelpath: nil, livePhotoStillTimeMs: nil,
                videoCodec: meta.codec, colorSpace: meta.colorSpace,
                hasAudio: meta.hasAudio, frameRate: meta.frameRate,
                editRecipeJSON: nil, editVersion: 0
            )
            try await db.execute(Asset.insertSQL, asset.insertBindings)
            progress.completed += 1
            outcome.importedUUIDs.append(uuid)
        } catch {
            progress.failed += 1
            outcome.failures.append(.init(filename: url.lastPathComponent,
                                          message: error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private func expandInputs(_ inputs: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in inputs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]) {
                    for case let file as URL in enumerator {
                        result.append(file)
                    }
                }
            } else {
                result.append(url)
            }
        }
        return result
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 4 * 1024 * 1024)
            if let chunk, !chunk.isEmpty {
                hasher.update(data: chunk)
                return true
            }
            return false
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isDuplicate(_ hash: String) async throws -> Bool {
        try await db.scalarInt("SELECT COUNT(*) FROM assets WHERE sha256 = ?", [.text(hash)]) > 0
    }

    private func fileModificationDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
    }

    private func utiString(for url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier
    }
}
