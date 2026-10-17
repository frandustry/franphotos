import AVFoundation
import SwiftUI

/// The still↔video stage: still layer always rendered underneath (HDR-capable),
/// video layer fades in/out on top. Used by the detail view, the preview sheet,
/// and (muted, hover-driven) grid cells.
struct MediaStageView: View {
    let asset: Asset
    let paths: LibraryPaths
    var autoplay: Bool = false
    var muted: Bool = false
    var showsControls: Bool = false
    /// LIVE badge top-left; hovering it (300 ms debounce) plays the live photo.
    var showsLiveBadge: Bool = true
    var onVideoFinished: (() -> Void)?

    @State private var controller: MediaStageController?
    @State private var liveHoverDebounce: Task<Void, Never>?

    var body: some View {
        ZStack {
            stillLayer
            if let controller, controller.hasVideo {
                VideoLayerView(player: controller.player)
                    .opacity(controller.videoLayerOpacity)
                    .animation(.easeInOut(duration: 0.15), value: controller.playbackState)
            }
            if showsControls, let controller, controller.hasVideo, asset.isVideo {
                controlsOverlay(controller)
            }
            if showsLiveBadge, asset.isLivePhoto, let controller {
                liveBadge(controller)
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture {
            controller?.togglePlayPause()
        }
        .onAppear {
            let controller = MediaStageController(asset: asset, paths: paths)
            controller.isMuted = muted
            controller.onFinished = onVideoFinished
            self.controller = controller
            if autoplay && controller.hasVideo {
                controller.play()
            }
        }
        .onDisappear {
            liveHoverDebounce?.cancel()
            controller?.teardown()
        }
    }

    /// LIVE badge: hovering plays (mirrors Apple Photos), leaving stops.
    private func liveBadge(_ controller: MediaStageController) -> some View {
        VStack {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: controller.playbackState == .playing
                          ? "livephoto" : "livephoto")
                    Text("LIVE")
                }
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(12)
                .contentShape(Rectangle())
                .onHover { hovering in
                    liveHoverDebounce?.cancel()
                    if hovering {
                        liveHoverDebounce = Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled else { return }
                            controller.play()
                        }
                    } else {
                        controller.returnToStill()
                    }
                }
                Spacer()
                if asset.hdrType != .sdr {
                    Text("HDR")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(12)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var stillLayer: some View {
        if asset.mediaType == .video && !asset.isLivePhoto {
            // Poster from the derivative cache (video first frame).
            PosterStillView(asset: asset, paths: paths)
        } else {
            HDRAssetView(asset: asset, paths: paths)
        }
    }

    private func controlsOverlay(_ controller: MediaStageController) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Button {
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.playbackState == .playing
                          ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                .buttonStyle(.plain)
                Slider(
                    value: Binding(
                        get: { controller.currentTime },
                        set: { controller.seek(toSeconds: $0) }
                    ),
                    in: 0...max(controller.duration, 0.01)
                )
                Text(MediaStageController.timeString(controller.currentTime))
                    .font(.caption.monospacedDigit())
                Text(MediaStageController.timeString(controller.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    controller.isMuted.toggle()
                } label: {
                    Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }
}

/// Poster still for videos (derivative cache → AVAssetImageGenerator).
private struct PosterStillView: View {
    let asset: Asset
    let paths: LibraryPaths
    @Environment(LibraryManager.self) private var manager
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                Color.black
            }
        }
        .task {
            guard let cache = manager.derivativeCache else { return }
            image = await cache.image(for: asset, size: .screen)
        }
    }
}

extension MediaStageController {
    /// Formatted "m:ss" for the scrubber.
    static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
