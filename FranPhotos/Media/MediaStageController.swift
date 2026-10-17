import AVFoundation
import Foundation

/// State machine driving the seamless still↔video crossfade (MediaStageView).
///
/// The video layer is pre-seeked to the still time while invisible, so the first
/// visible frame matches the still exactly — no black flash, no jump.
@MainActor
@Observable
final class MediaStageController {
    enum PlaybackState: Equatable {
        case still        // showing the still/poster, video layer hidden
        case prewarming   // player created, seeking to the still frame
        case playing      // video layer visible and playing
        case returning    // fading back to the still
    }

    let asset: Asset
    private let paths: LibraryPaths

    private(set) var playbackState: PlaybackState = .still
    private(set) var player: AVPlayer?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    /// Grid hover previews are muted; detail playback is not.
    var isMuted: Bool = false {
        didSet { player?.isMuted = isMuted }
    }

    var onFinished: (() -> Void)?

    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var prewarmTask: Task<Void, Never>?

    /// Seconds into the video matching the still image (live photos).
    private let stillTimeSeconds: Double

    init(asset: Asset, paths: LibraryPaths) {
        self.asset = asset
        self.paths = paths
        if asset.isLivePhoto, let rel = asset.livePhotoVideoRelpath {
            stillTimeSeconds = Double(asset.livePhotoStillTimeMs ?? 0) / 1000
        } else {
            stillTimeSeconds = 0
        }
    }

    var videoURL: URL? {
        if asset.isLivePhoto, let rel = asset.livePhotoVideoRelpath {
            return paths.url(forRelativePath: rel)
        }
        if asset.mediaType == .video {
            return paths.url(forRelativePath: asset.originalRelpath)
        }
        return nil
    }

    var hasVideo: Bool { videoURL != nil }

    var videoLayerOpacity: Double {
        switch playbackState {
        case .playing: 1.0
        default: 0.0
        }
    }

    // MARK: - Lifecycle

    /// Creates the player (pooled) and seeks it to the still frame while hidden.
    /// Safe to call repeatedly; cheap no-op when already warm.
    func prewarm() {
        guard let videoURL, playbackState == .still else { return }
        playbackState = .prewarming
        prewarmTask = Task { [weak self] in
            guard let self else { return }
            let player = PlayerPool.shared.player(for: videoURL)
            player.isMuted = isMuted
            if player.currentItem == nil {
                // PlayerPool creates with URL; ensure an item exists.
                // (AVPlayer(url:) always has a currentItem, but be defensive.)
                player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
            }
            let stillTime = CMTime(seconds: stillTimeSeconds, preferredTimescale: 600)
            _ = await player.currentItem?.seek(
                to: stillTime, toleranceBefore: .zero, toleranceAfter: .zero)
            if let item = player.currentItem {
                duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            }
            guard !Task.isCancelled else {
                playbackState = .still
                return
            }
            self.player = player
            playbackState = .still  // warm and ready, still showing the photo
            installObservers(player: player)
        }
    }

    /// Hover ended before playback started: cancel prewarm.
    func cancelPrewarm() {
        guard playbackState == .prewarming else { return }
        prewarmTask?.cancel()
        prewarmTask = nil
        playbackState = .still
    }

    // MARK: - Playback

    func play() {
        guard hasVideo else { return }
        if player == nil {
            prewarm()
        }
        Task { [weak self] in
            guard let self else { return }
            // Wait until the prewarm finishes (bounded).
            for _ in 0..<40 where player == nil {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard let player else { return }
            playbackState = .playing
            player.play()
        }
    }

    func pause() {
        player?.pause()
        playbackState = .still
    }

    /// Stop and return to the still frame (used when playback ends or is dismissed).
    func returnToStill() {
        guard playbackState == .playing || playbackState == .returning else { return }
        playbackState = .returning
        player?.pause()
        let player = self.player
        let stillTime = CMTime(seconds: stillTimeSeconds, preferredTimescale: 600)
        Task { [weak self] in
            _ = await player?.seek(to: stillTime, toleranceBefore: .positiveInfinity,
                                   toleranceAfter: .positiveInfinity)
            guard let self else { return }
            self.playbackState = .still
        }
    }

    func togglePlayPause() {
        switch playbackState {
        case .playing: pause()
        default: play()
        }
    }

    func seek(toSeconds seconds: Double) {
        guard playbackState == .playing || player != nil else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .positiveInfinity,
                     toleranceAfter: .positiveInfinity)
    }

    func teardown() {
        prewarmTask?.cancel()
        removeObservers()
        if let url = videoURL {
            PlayerPool.shared.release(url)
        }
        player = nil
        playbackState = .still
    }

    // MARK: - Observers

    private func installObservers(player: AVPlayer) {
        removeObservers()
        guard let item = player.currentItem else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.returnToStill()
                self.onFinished?()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
        if let item = player.currentItem {
            duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
        }
    }

    private func removeObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
}
