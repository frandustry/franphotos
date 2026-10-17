import SwiftUI

/// A grid cell thumbnail with badges (video duration, LIVE, HDR, favorite).
struct AssetThumbnailView: View {
    let asset: Asset
    let cache: DerivativeCache
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
            badges
        }
        .clipped()
        .aspectRatio(1, contentMode: .fit)
        .task(id: asset.editVersion) {
            image = await cache.image(for: asset, size: .thumb)
        }
    }

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
