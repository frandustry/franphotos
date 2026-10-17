import SwiftUI

/// Grid cell with badges AND hover-to-play (muted inline playback for videos and
/// live photos, like Apple Photos). Playback is debounced by ~300 ms so skimming
/// across the grid never spawns decoders.
struct AssetThumbnailView: View {
    let asset: Asset
    let cache: DerivativeCache
    var paths: LibraryPaths? = nil

    @AppStorage("hoverPlaybackEnabled") private var hoverPlaybackEnabled = true

    @State private var image: NSImage?
    @State private var controller: MediaStageController?
    @State private var hoverDebounce: Task<Void, Never>?

    private let hoverDelayNanoseconds: UInt64 = 300_000_000

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.secondary.opacity(0.12))
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
        .clipped()
        .aspectRatio(1, contentMode: .fit)
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
        HStack(spacing: 4) {
            if asset.isLivePhoto {
                Image(systemName: "livephoto")
                    .font(.caption2.weight(.semibold))
            }
            if asset.hdrType != .sdr {
                Text("HDR")
                    .font(.system(size: 9, weight: .bold))
            }
            if asset.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
            }
            Spacer()
            if asset.isVideo, let ms = asset.durationMs {
                Text(Self.formatDuration(ms: ms))
                    .font(.caption2.monospacedDigit())
            }
        }
        .padding(4)
        .foregroundStyle(.white)
        .shadow(radius: 2)
    }

    static func formatDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
