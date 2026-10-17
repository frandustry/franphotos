import AppKit
import CoreImage
import CoreVideo
import MetalKit
import QuartzCore
import SwiftUI

/// Renders CIImages into Metal textures preserving extended dynamic range.
///
/// Path (verified end-to-end with >1.0 pixel values):
///   CIImage → CVPixelBuffer (64RGBAHalf, extended-linear Display P3)
///           → CVMetalTextureCache → fullscreen blit → drawable texture.
///
/// Note: `CIRenderDestination(mtlTexture:)` returns nil on macOS 27 and
/// `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` writes nothing into
/// plain textures — hence the explicit pixel-buffer + blit pipeline.
final class EDRPipeline: @unchecked Sendable {
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private let pipelineState: any MTLRenderPipelineState

    static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        ?? CGColorSpaceCreateDeviceRGB()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard let library = device.makeDefaultLibrary(),
              let vs = library.makeFunction(name: "edrBlitVS"),
              let fs = library.makeFunction(name: "edrBlitFS") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }
    }

    /// Renders `image` (aspect-fit into targetSize) into `texture`.
    /// `wait` is used by tests; on-screen rendering presents without waiting.
    @discardableResult
    func render(
        _ image: CIImage,
        into texture: any MTLTexture,
        targetSize: CGSize,
        wait: Bool = false
    ) -> Bool {
        guard texture.pixelFormat == .rgba16Float else { return false }
        let width = Int(targetSize.width), height = Int(targetSize.height)
        guard width > 0, height > 0, image.extent.width > 0, image.extent.height > 0
        else { return false }

        // 1. CIImage → pixel buffer in extended-linear Display P3.
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
            [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary,
            &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return false }
        // Aspect-fit: clear to black, render the image centered.
        let scale = min(targetSize.width / image.extent.width,
                        targetSize.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (targetSize.width - scaled.extent.width) / 2 - scaled.extent.origin.x
        let dy = (targetSize.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        let fitted = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let canvas = CIImage(color: .black)
            .cropped(to: CGRect(origin: .zero, size: targetSize))
        let composited = fitted.composited(over: canvas)
        HDRCompositor.sharedContext.render(
            composited, to: pixelBuffer,
            bounds: CGRect(origin: .zero, size: targetSize),
            colorSpace: EDRPipeline.colorSpace)

        // 2. pixel buffer → texture.
        guard let cache = textureCache else { return false }
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .rgba16Float, width, height, 0,
            &cvTexture) == kCVReturnSuccess,
              let cvTexture,
              let source = CVMetalTextureGetTexture(cvTexture)
        else { return false }

        // 3. Fullscreen blit into the destination.
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: blitPassDescriptor(into: texture))
        else { return false }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        if wait { commandBuffer.waitUntilCompleted() }
        return true
    }

    private func blitPassDescriptor(into texture: any MTLTexture) -> MTLRenderPassDescriptor {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = texture
        desc.colorAttachments[0].loadAction = .dontCare
        desc.colorAttachments[0].storeAction = .store
        return desc
    }
}

/// NSView whose CAMetalLayer displays CIImages with Extended Dynamic Range.
///
/// All HDR flavors converge on the same path: the incoming CIImage is composited
/// (gain map applied at the current display headroom, if any) and rendered into
/// an `extendedLinearDisplayP3` / `rgba16Float` layer. Values > 1.0 in extended-
/// linear space produce real HDR brightness on XDR displays; on SDR displays the
/// headroom is 1 and the same path yields tone-mapped SDR. One path, two outputs.
final class MetalEDRView: NSView {
    private var pipeline: EDRPipeline?
    private var screenObserver: NSObjectProtocol?

    /// Called when the view needs pixels for the current headroom.
    /// Return nil when nothing to render yet.
    var imageProvider: ((Float) -> CIImage?)?

    private(set) var currentHeadroom: Float = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        pipeline = EDRPipeline()
        configureLayer()
    }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    private func configureLayer() {
        guard let metalLayer, let pipeline else { return }
        metalLayer.device = pipeline.device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.framebufferOnly = false
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: - Rendering

    func reloadImage() {
        render()
    }

    func render() {
        guard let pipeline, let metalLayer else { return }
        currentHeadroom = Float(max(
            1.0, window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1))
        guard let image = imageProvider?(currentHeadroom) else { return }

        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * metalLayer.contentsScale),
            height: max(1, bounds.height * metalLayer.contentsScale))
        guard let drawable = metalLayer.nextDrawable() else { return }
        let succeeded = pipeline.render(
            image, into: drawable.texture, targetSize: metalLayer.drawableSize)
        if succeeded {
            // Present in a fresh command buffer (the render pass already committed).
            if let cb = pipeline.commandQueue.makeCommandBuffer() {
                cb.present(drawable)
                cb.commit()
            }
        }
    }

    // MARK: - Layout & screen tracking

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        metalLayer?.contentsScale = window?.backingScaleFactor ?? 2
        render()
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        if let window {
            // Re-render when the window moves to a screen with different EDR headroom.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
        }
    }
}

/// SwiftUI wrapper around MetalEDRView.
struct HDRImageView: NSViewRepresentable {
    /// Provides the composited CIImage for a requested headroom (1.0 = SDR).
    let imageProvider: (Float) -> CIImage?

    /// Bump to force a reload (e.g. after edits).
    var contentVersion: Int = 0

    func makeNSView(context: Context) -> MetalEDRView {
        let view = MetalEDRView()
        view.imageProvider = imageProvider
        return view
    }

    func updateNSView(_ nsView: MetalEDRView, context: Context) {
        nsView.imageProvider = imageProvider
        nsView.reloadImage()
    }
}
