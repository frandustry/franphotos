import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Applies an EditRecipe to a CIImage and renders edit derivatives.
/// Everything is pure CoreImage — deterministic and replayable.
enum EditEngine {
    static var context: CIContext { HDRCompositor.sharedContext }

    // MARK: - Recipe application

    static func apply(_ recipe: EditRecipe, to input: CIImage) -> CIImage {
        var image = input

        // Geometry first: rotate/flip/straighten/crop.
        image = applyGeometry(recipe: recipe, to: image)

        // Light.
        if recipe.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(recipe.exposure)
            image = f.outputImage ?? image
        }
        if recipe.highlights != 0 || recipe.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(1.0 - recipe.highlights)  // CI: 1 = no change
            f.shadowAmount = Float(recipe.shadows)              // CI: 0 = no change
            image = f.outputImage ?? image
        }
        if recipe.brilliance != 0 {
            // Approximation: brilliance ≈ gentle highlight-rolloff with midtone lift.
            let f = CIFilter.gammaAdjust()
            f.inputImage = image
            f.power = Float(1.0 / (1.0 + recipe.brilliance * 0.35))
            image = f.outputImage ?? image
        }
        if recipe.contrast != 0 || recipe.brightness != 0 || recipe.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(1.0 + recipe.contrast * 0.5)
            f.brightness = Float(recipe.brightness * 0.18)
            f.saturation = Float(1.0 + recipe.saturation)
            image = f.outputImage ?? image
        }
        if recipe.blackPoint != 0 {
            let f = CIFilter.toneCurve()
            f.inputImage = image
            f.point0 = CGPoint(x: 0, y: max(0, recipe.blackPoint) * 0.15)
            image = f.outputImage ?? image
        }

        // Color.
        if recipe.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(recipe.vibrance)
            image = f.outputImage ?? image
        }
        if recipe.warmth != 0 || recipe.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500 + CGFloat(recipe.warmth) * -2500,
                                 y: CGFloat(recipe.tint) * 40)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            image = f.outputImage ?? image
        }

        // Creative filter (before detail work, like Photos).
        if let name = recipe.filterName, let filter = PhotoFilter(rawValue: name) {
            image = applyFilter(filter, intensity: recipe.filterIntensity, to: image)
        }

        // Detail.
        if recipe.definition != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = image
            f.radius = 30
            f.intensity = Float(recipe.definition * 0.6)
            image = f.outputImage ?? image
        }
        if recipe.noiseReduction > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = image
            f.noiseLevel = Float(recipe.noiseReduction * 0.08)
            f.sharpness = 0.5
            image = f.outputImage ?? image
        }
        if recipe.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(recipe.sharpness * 1.5)
            image = f.outputImage ?? image
        }
        if recipe.vignette != 0 {
            let f = CIFilter.vignette()
            f.inputImage = image
            f.radius = 1.5
            f.intensity = Float(recipe.vignette * 1.4)
            image = f.outputImage ?? image
        }
        return image
    }

    private static func applyGeometry(recipe: EditRecipe, to input: CIImage) -> CIImage {
        var image = input
        let turns = ((recipe.rotationQuarterTurns % 4) + 4) % 4
        for _ in 0..<turns {
            image = image.oriented(.right)  // 90° clockwise per turn
        }
        if recipe.flipHorizontal {
            let extent = image.extent
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: extent.width, y: 0))
        }
        if recipe.straightenDegrees != 0 {
            let extent = image.extent
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let angle = -recipe.straightenDegrees * .pi / 180
            image = image.transformed(by: CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
                .translatedBy(x: -center.x, y: -center.y))
            // Crop back to the largest inscribed rect to avoid transparent corners.
            image = inscribedRectCrop(image: image, degrees: recipe.straightenDegrees)
        }
        if let crop = recipe.crop {
            let extent = image.extent
            let rect = CGRect(
                x: extent.minX + crop.x * extent.width,
                y: extent.minY + crop.y * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height)
            image = image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        return image
    }

    /// Largest axis-aligned rect inside a rect rotated by `degrees`.
    private static func inscribedRectCrop(image: CIImage, degrees: Double) -> CIImage {
        let extent = image.extent
        let angle = abs(degrees).truncatingRemainder(dividingBy: 90) * .pi / 180
        guard angle > 0.0001, angle < .pi / 2 - 0.0001 else { return image }
        let w = extent.width, h = extent.height
        let sinA = sin(angle), cosA = cos(angle)
        let isPortrait = h > w
        let (a, b) = isPortrait ? (h, w) : (w, h)
        let scale = a / (b * sinA + a * cosA)
        let newW = isPortrait ? b * scale : a * scale
        let newH = isPortrait ? a * scale : b * scale
        let rect = CGRect(x: extent.midX - newW / 2, y: extent.midY - newH / 2,
                          width: newW, height: newH)
        return image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    // MARK: - Creative filters

    static func applyFilter(_ filter: PhotoFilter, intensity: Double, to input: CIImage) -> CIImage {
        let blended: (CIImage) -> CIImage = { filtered in
            guard intensity < 1.0 else { return filtered }
            // Cross-fade between original and filtered by intensity.
            let f = CIFilter.dissolveTransition()
            f.inputImage = input
            f.targetImage = filtered
            f.time = Float(intensity)
            return f.outputImage ?? filtered
        }
        switch filter {
        case .vivid:
            let f = CIFilter.colorControls()
            f.inputImage = input
            f.saturation = 1.45
            f.contrast = 1.12
            return blended(f.outputImage ?? input)
        case .dramatic:
            let controls = CIFilter.colorControls()
            controls.inputImage = input
            controls.saturation = 1.1
            controls.contrast = 1.28
            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = controls.outputImage
            unsharp.radius = 25
            unsharp.intensity = 0.5
            return blended(unsharp.outputImage ?? input)
        case .mono:
            let f = CIFilter.photoEffectMono()
            f.inputImage = input
            return blended(f.outputImage ?? input)
        case .silvertone:
            let f = CIFilter.photoEffectTonal()
            f.inputImage = input
            return blended(f.outputImage ?? input)
        case .noir:
            let f = CIFilter.photoEffectNoir()
            f.inputImage = input
            return blended(f.outputImage ?? input)
        case .warm:
            let f = CIFilter.temperatureAndTint()
            f.inputImage = input
            f.neutral = CIVector(x: 5000, y: 0)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            return blended(f.outputImage ?? input)
        case .cool:
            let f = CIFilter.temperatureAndTint()
            f.inputImage = input
            f.neutral = CIVector(x: 8500, y: 0)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            return blended(f.outputImage ?? input)
        case .fade:
            let f = CIFilter.photoEffectFade()
            f.inputImage = input
            return blended(f.outputImage ?? input)
        case .chrome:
            let f = CIFilter.photoEffectChrome()
            f.inputImage = input
            return blended(f.outputImage ?? input)
        case .process:
            let f = CIFilter.photoEffectProcess()
            f.inputImage = input
            return blended(f.outputImage ?? input)
        }
    }

    /// Apple's "Auto" equivalent: let CoreImage analyze the image and map its
    /// suggested adjustments onto our recipe.
    static func autoRecipe(for image: CIImage) -> EditRecipe {
        var recipe = EditRecipe()
        let options: [CIImageAutoAdjustmentOption: Any] = [
            .enhance: true,
            .redEye: false,
            .crop: false,
        ]
        let filters = image.autoAdjustmentFilters(options: options)
        for filter in filters {
            if filter.name == "CIExposureAdjust", let ev = filter.value(forKey: "inputEV") as? Double {
                recipe.exposure = max(-1.5, min(1.5, ev))
            }
            if filter.name == "CIColorControls" {
                if let sat = filter.value(forKey: "inputSaturation") as? Double {
                    recipe.saturation = max(-0.5, min(1.0, sat - 1.0))
                }
                if let con = filter.value(forKey: "inputContrast") as? Double {
                    recipe.contrast = max(-0.5, min(1.0, (con - 1.0) * 2))
                }
            }
            if filter.name == "CIVibrance", let amount = filter.value(forKey: "inputAmount") as? Double {
                recipe.vibrance = max(-0.5, min(1.0, amount))
            }
        }
        return recipe
    }

    // MARK: - Rendering

    /// Renders the edited image and writes it to `derivatives/edits/<uuid>/v<version>.jpg`.
    /// Returns the relative path on success.
    static func renderEditDerivative(
        asset: Asset, recipe: EditRecipe, version: Int, paths: LibraryPaths
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let original = paths.url(forRelativePath: asset.originalRelpath)
            guard let base = ImageDecoder.fullImage(at: original) else { return nil as String? }
            var image = CIImage(cgImage: base)
            image = apply(recipe, to: image)
            let extent = image.extent
            guard extent.width > 0, extent.height > 0,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let cg = context.createCGImage(image, from: extent, format: .RGBA8,
                                                 colorSpace: colorSpace)
            else { return nil as String? }
            let rel = "derivatives/edits/\(asset.uuid.uuidString)/v\(version).jpg"
            let dest = paths.url(forRelativePath: rel)
            try? FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard ImageDecoder.writeJPEG(cg, to: dest, quality: 0.9) else { return nil as String? }
            return rel
        }.value
    }

    /// Path of the current edit derivative, if it exists.
    static func editDerivativeURL(asset: Asset, paths: LibraryPaths) -> URL? {
        guard asset.editVersion > 0 else { return nil }
        let url = paths.url(forRelativePath:
            "derivatives/edits/\(asset.uuid.uuidString)/v\(asset.editVersion).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
