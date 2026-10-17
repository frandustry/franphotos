import CoreGraphics
import Foundation

/// Derivative rendition sizes. Derivatives are SDR (tone-mapped when the source
/// is HDR) and regenerable at any time from the original.
enum DerivativeSize: String, Sendable, CaseIterable {
    case thumb   // grid cells
    case screen  // detail view before the full-resolution pipeline kicks in

    /// Maximum pixel dimension of the longest edge, in *points* (multiplied by scale at render time).
    var basePixels: Int {
        switch self {
        case .thumb: 288
        case .screen: 1456
        }
    }

    /// JPEG compression quality for on-disk derivatives.
    var jpegQuality: Double {
        switch self {
        case .thumb: 0.82
        case .screen: 0.88
        }
    }

    func relativePath(for uuid: UUID) -> String {
        switch self {
        case .thumb: "derivatives/thumbs/\(uuid.uuidString).jpg"
        case .screen: "derivatives/screen/\(uuid.uuidString).jpg"
        }
    }

    func url(for uuid: UUID, in paths: LibraryPaths) -> URL {
        paths.url(forRelativePath: relativePath(for: uuid))
    }
}
