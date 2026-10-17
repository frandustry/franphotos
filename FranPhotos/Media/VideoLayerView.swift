import AppKit
import AVFoundation
import SwiftUI

/// AVPlayerLayer-backed view. The player layer never blanks the stage:
/// MediaStageView only fades this layer in once the first frame is ready.
struct VideoLayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> VideoLayerNSView {
        VideoLayerNSView()
    }

    func updateNSView(_ nsView: VideoLayerNSView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class VideoLayerNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer  // swiftlint:disable:this force_cast
    }
}
