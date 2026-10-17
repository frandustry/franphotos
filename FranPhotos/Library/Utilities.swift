import Foundation

extension Collection {
    /// Safe subscript: nil instead of trapping out of bounds.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
