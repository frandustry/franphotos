import CoreImage
import Foundation
import Testing
@testable import FranPhotos

struct EditEngineTests {
    private func grayImage(_ value: Double = 0.5, size: Int = 32) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// Renders to 1×1-equivalent average RGB by scaling down to 1x1.
    private func averageColor(_ image: CIImage) -> (r: Double, g: Double, b: Double)? {
        let tiny = image.transformed(by: CGAffineTransform(
            scaleX: 1.0 / image.extent.width, y: 1.0 / image.extent.height))
        guard let cg = HDRCompositor.sharedContext.createCGImage(
            tiny, from: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        let data = cg.dataProvider?.data
        guard let ptr = data.map({ CFDataGetBytePtr($0) }) else { return nil }
        return (Double(ptr![0]) / 255, Double(ptr![1]) / 255, Double(ptr![2]) / 255)
    }

    @Test func exposureBrightens() {
        var recipe = EditRecipe()
        recipe.exposure = 1.0
        let out = EditEngine.apply(recipe, to: grayImage(0.25))
        guard let before = averageColor(grayImage(0.25)),
              let after = averageColor(out) else {
            Issue.record("render failed")
            return
        }
        #expect(after.r > before.r + 0.1)
    }

    @Test func monoFilterDesaturates() {
        // Start from a saturated red; mono must equalize channels.
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        var recipe = EditRecipe()
        recipe.filterName = PhotoFilter.mono.rawValue
        let out = EditEngine.apply(recipe, to: red)
        guard let color = averageColor(out) else {
            Issue.record("render failed")
            return
        }
        #expect(abs(color.r - color.g) < 0.05)
        #expect(abs(color.g - color.b) < 0.05)
    }

    @Test func cropReducesExtent() {
        var recipe = EditRecipe()
        recipe.crop = .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let out = EditEngine.apply(recipe, to: grayImage())
        #expect(out.extent.width == 16)
        #expect(out.extent.height == 16)
    }

    @Test func rotationSwapsDimensions() {
        var recipe = EditRecipe()
        recipe.rotationQuarterTurns = 1
        let landscape = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let out = EditEngine.apply(recipe, to: landscape)
        #expect(out.extent.width == 32)
        #expect(out.extent.height == 64)
    }

    @Test func recipeJSONRoundTrip() throws {
        var recipe = EditRecipe()
        recipe.exposure = 0.7
        recipe.filterName = "vivid"
        recipe.crop = .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        recipe.rotationQuarterTurns = 3
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded == recipe)
        #expect(!decoded.isEmpty)
        #expect(EditRecipe().isEmpty)
    }
}
