import SwiftUI

/// Grid cell with badges AND hover-to-play (muted inline playback for videos and
/// live photos, like Apple Photos). Playback is debounced by ~300 ms so skimming
/// across the grid never spawns decoders.
struct AssetThumbnailView: View {
    let asset: Asset
    let cache: DerivativeCache
    var paths: LibraryPaths? = nil
    /// Explicit square edge in points. Grids always pass the exact computed
    /// cell size so the image is cropped to a uniform square; nil falls back
    /// to a 1:1 aspect-ratio constraint (used by callers that frame the view
    /// themselves).
    var size: Double? = nil

    @AppStorage("hoverPlaybackEnabled") private var hoverPlaybackEnabled = true

    @State private var image: NSImage?
    @State private var controller: MediaStageController?
    @State private var hoverDebounce: Task<Void, Never>?

    private let hoverDelayNanoseconds: UInt64 = 300_000_000
    static let cornerRadius: CGFloat = 6

    var body: some View {
        sizedContent
            .task(id: asset.editVersion) {
                image = await cache.image(for: asset, size: .thumb)
            }
            .onHover { hovering in
                guard hoverPlaybackEnabled, asset.isVideo || asset.isLivePhoto else { return }
                if hovering {
                    startHoverPlayback()
                } else {
                    stopHoverPlayback()
                }
            }
            .onDisappear {
                stopHoverPlayback()
            }
    }

    @ViewBuilder
    private var sizedContent: some View {
        if let size {
            cellContent.frame(width: size, height: size)
        } else {
            cellContent.aspectRatio(1, contentMode: .fit)
        }
    }

    private var cellContent: some View {
        ZStack {
            placeholder
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
            if let controller, controller.hasVideo {
                VideoLayerView(player: controller.player)
                    .opacity(controller.videoLayerOpacity)
                    .animation(.easeInOut(duration: 0.15), value: controller.playbackState)
                    .allowsHitTesting(false)
            }
            badges
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            Image(systemName: asset.isVideo ? "video" : "photo")
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: - Hover playback

    private func startHoverPlayback() {
        hoverDebounce?.cancel()
        hoverDebounce = Task { [asset, paths] in
            try? await Task.sleep(nanoseconds: hoverDelayNanoseconds)
            guard !Task.isCancelled, let paths else { return }
            if controller == nil {
                let c = MediaStageController(asset: asset, paths: paths)
                c.isMuted = true
                controller = c
            }
            controller?.play()
        }
    }

    private func stopHoverPlayback() {
        hoverDebounce?.cancel()
        hoverDebounce = nil
        controller?.returnToStill()
        // Release the decoder promptly; PlayerPool would LRU it anyway.
        let c = controller
        Task { [asset, paths] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Only tear down if it stayed idle.
            if let c, c.playbackState == .still {
                c.teardown()
                if controller === c { controller = nil }
            }
            _ = asset
            _ = paths
        }
    }

    // MARK: - Badges

    @ViewBuilder
    private var badges: some View {
        VStack(spacing: 0) {
            HStack {
                if asset.isLivePhoto {
                    BadgeLabel(icon: "livephoto")
                }
                Spacer()
                if asset.hdrType != .sdr {
                    BadgeLabel(text: "HDR")
                }
            }
            Spacer()
            HStack {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1.5, y: 0.5)
                }
                Spacer()
                if asset.isVideo, let ms = asset.durationMs {
                    BadgeLabel(icon: "video.fill", text: Self.formatDuration(ms: ms))
                }
            }
        }
        .padding(5)
        .allowsHitTesting(false)
    }

    /// Small translucent capsule used for LIVE / HDR / duration badges.
    private struct BadgeLabel: View {
        var icon: String? = nil
        var text: String? = nil

        var body: some View {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                }
                if let text {
                    Text(text)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.55), in: Capsule())
        }
    }

    static func formatDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
