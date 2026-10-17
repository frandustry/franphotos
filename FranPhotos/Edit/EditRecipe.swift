import Foundation

/// Non-destructive edit recipe stored as JSON in `assets.edit_recipe_json`.
/// The original file is never touched; renders go to `derivatives/edits/`.
struct EditRecipe: Codable, Sendable, Equatable {
    // Light
    var exposure: Double = 0       // EV stops, −2…2
    var brilliance: Double = 0     // −1…1
    var highlights: Double = 0     // −1…1 (positive recovers)
    var shadows: Double = 0        // −1…1 (positive lifts)
    var contrast: Double = 0       // −1…1
    var brightness: Double = 0     // −1…1
    var blackPoint: Double = 0     // −1…1
    // Color
    var saturation: Double = 0     // −1…1
    var vibrance: Double = 0       // −1…1
    var warmth: Double = 0         // −1…1 (cool…warm)
    var tint: Double = 0           // −1…1 (green…magenta)
    // Detail
    var definition: Double = 0     // −1…1 (local contrast)
    var noiseReduction: Double = 0 // 0…1
    var sharpness: Double = 0      // 0…1
    var vignette: Double = 0       // −1…1
    // Geometry
    var rotationQuarterTurns: Int = 0
    var straightenDegrees: Double = 0  // −45…45
    var flipHorizontal: Bool = false
    var crop: CropRect?            // normalized in the rotated frame
    // Creative filter
    var filterName: String?        // see PhotoFilter
    var filterIntensity: Double = 1.0

    struct CropRect: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var isEmpty: Bool {
        self == EditRecipe()
    }
}

/// Apple-style creative filters mapped to CoreImage.
enum PhotoFilter: String, CaseIterable, Sendable {
    case vivid, dramatic, mono, silvertone, noir, warm, cool, fade, chrome, process

    var localizedName: String {
        switch self {
        case .vivid: String(localized: "Vivid")
        case .dramatic: String(localized: "Dramatic")
        case .mono: String(localized: "Mono")
        case .silvertone: String(localized: "Silvertone")
        case .noir: String(localized: "Noir")
        case .warm: String(localized: "Warm")
        case .cool: String(localized: "Cool")
        case .fade: String(localized: "Fade")
        case .chrome: String(localized: "Chrome")
        case .process: String(localized: "Process")
        }
    }
}
