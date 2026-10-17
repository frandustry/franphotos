import Foundation

/// Pairs photo+video files into Live Photos during import.
///
/// Rules (mirroring Apple Photos behavior):
/// 1. Same directory + same filename stem, case-insensitive
///    (`IMG_1234.HEIC` + `IMG_1234.MOV`) → pair.
/// 2. The video must be short (≤ 3.5 s) — long videos are real videos.
///
/// Paired videos are never imported as standalone assets; their bytes live
/// next to the still inside the library as `<uuid>.mov`.
enum LivePhotoPairer {
    static let maxLiveVideoDurationMs = 3500

    struct PairingPlan: Sendable {
        /// photo URL → video URL for confirmed pairs.
        var pairs: [URL: URL] = [:]
        /// photos with no video partner.
        var lonePhotos: [URL] = []
        /// videos with no photo partner (imported as standalone videos).
        var loneVideos: [URL] = []
    }

    /// `candidates` are raw file URLs already classified as photo or video.
    /// `videoDurationMs` resolves the duration for a video URL (async, may be cached by caller).
    static func plan(
        photos: [URL],
        videos: [URL],
        videoDurationMs: (URL) async -> Int?
    ) async -> PairingPlan {
        var plan = PairingPlan()

        var videosByStem: [String: URL] = [:]
        for video in videos {
            let key = stemKey(for: video)
            // First writer wins on collisions; deterministic by sorted input.
            if videosByStem[key] == nil { videosByStem[key] = video }
        }

        var pairedVideos: Set<URL> = []
        for photo in photos {
            guard let video = videosByStem[stemKey(for: photo)], !pairedVideos.contains(video)
            else {
                plan.lonePhotos.append(photo)
                continue
            }
            let duration = await videoDurationMs(video)
            if let duration, duration <= maxLiveVideoDurationMs {
                plan.pairs[photo] = video
                pairedVideos.insert(video)
            } else {
                plan.lonePhotos.append(photo)
            }
        }
        plan.loneVideos = videos.filter { !pairedVideos.contains($0) }
        return plan
    }

    /// Directory + lowercase stem, so "IMG_1.HEIC"/"IMG_1.MOV" in the same folder pair up.
    private static func stemKey(for url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.path
            + "/"
            + url.deletingPathExtension().lastPathComponent.lowercased()
    }
}
