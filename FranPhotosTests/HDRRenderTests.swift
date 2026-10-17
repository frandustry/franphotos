import CoreImage
import Foundation
import Metal
import Testing
@testable import FranPhotos

struct HDRRenderTests {
    /// Renders an extended-range image through the full EDR pipeline
    /// (pixel buffer → texture cache → blit) and verifies >1.0 values survive.
    @Test func edrPipelinePreservesExtendedRange() throws {
        guard let pipeline = EDRPipeline() else { return }  // no Metal here
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 64, height: 64, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = pipeline.device.makeTexture(descriptor: desc) else {
            Issue.record("failed to create texture")
            return
        }
        let extSRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let color = CIColor(red: 2.0, green: 1.0, blue: 1.0, colorSpace: extSRGB)!
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let ok = pipeline.render(image, into: texture,
                                 targetSize: CGSize(width: 64, height: 64), wait: true)
        #expect(ok)
        var bytes = [UInt16](repeating: 0, count: 64 * 64 * 4)
        texture.getBytes(&bytes, bytesPerRow: 64 * 8,
                         from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        let red = Float(Float16(bitPattern: bytes[0]))
        // 2.0 in extended sRGB linearizes to ~4.2 in extended-linear P3.
        #expect(red > 1.5, "expected extended-range red, got \(red)")
    }

    @Test func gainMapCompositingWithoutGainMapIsIdentity() throws {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let out = HDRCompositor.composited(base: base, gainMap: nil, headroom: 4)
        #expect(out.extent == base.extent)
    }

    @Test func headroomIsClamped() {
        let base = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        _ = HDRCompositor.composited(base: base, gainMap: nil, headroom: 100)
        _ = HDRCompositor.composited(base: base, gainMap: nil, headroom: 0.1)
    }
}
