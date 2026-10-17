import SwiftUI

/// Fullscreen slideshow over an asset list: photos crossfade on a timer,
/// videos play inline and advance when finished.
struct SlideshowView: View {
    let assets: [Asset]
    let paths: LibraryPaths
    var onClose: () -> Void

    @AppStorage("slideshowIntervalSeconds") private var interval: Double = 3.0
    @State private var index = 0
    @State private var advanceTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let asset = currentAsset {
                MediaStageView(
                    asset: asset, paths: paths,
                    autoplay: asset.mediaType == .video,
                    muted: false,
                    showsControls: false,
                    onVideoFinished: { advance() }
                )
                .id(asset.id)
                .transition(.opacity)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: { onClose() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
                Text("\(index + 1) / \(assets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 10)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.rightArrow) { advance(); return .handled }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onKeyPress(.space) { advance(); return .handled }
        .onAppear { scheduleAdvance() }
        .onDisappear { advanceTask?.cancel() }
    }

    private var currentAsset: Asset? {
        assets[safe: index]
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        advanceTask = Task {
            while !Task.isCancelled {
                let current = currentAsset
                // Photos: fixed interval. Videos: MediaStageView advances on finish.
                let wait = current?.mediaType == .video ? 3600 : interval
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if current?.mediaType != .video {
                    advance()
                }
            }
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.5)) {
            if index + 1 < assets.count {
                index += 1
            } else {
                index = 0  // loop
            }
        }
    }

    private func back() {
        withAnimation(.easeInOut(duration: 0.5)) {
            index = max(0, index - 1)
        }
    }
}
