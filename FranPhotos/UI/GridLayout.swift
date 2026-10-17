import SwiftUI

/// Uniform square-cell layout math shared by all asset grids: given the
/// container width and a target cell size (from the zoom slider), computes an
/// integer column count and an exact cell edge so every row fills the width
/// perfectly — the Apple Photos look. Explicit fixed-size grid items also
/// skip LazyVGrid's adaptive size negotiation, which is measurably cheaper
/// and avoids the ambiguous-proposal sizing leaks that let image natural
/// aspect ratios distort cells.
enum GridLayout {
    static let spacing: Double = 4
    static let horizontalPadding: Double = 4

    /// Returns one fixed-size GridItem per column plus the exact square cell
    /// edge. Column count is derived from the slider's target size; the cell
    /// edge is then adjusted so `count` cells plus spacing equal the usable
    /// width exactly.
    static func layout(containerWidth: Double, target: Double) -> (columns: [GridItem], cell: Double) {
        let usable = max(0, containerWidth - horizontalPadding * 2)
        let count = max(1, Int((usable + spacing) / (target + spacing)))
        let cell = max(32, ((usable - spacing * Double(count - 1)) / Double(count)).rounded(.down))
        let columns = Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: count)
        return (columns, cell)
    }
}
