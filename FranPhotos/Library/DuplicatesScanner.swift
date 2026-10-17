import CoreGraphics
import Foundation
import Vision

/// Visually-similar duplicate detection via Vision feature prints.
/// Exact byte-duplicates are prevented at import (SHA-256 unique), so this finds
/// near-duplicates: bursts, re-encodes, crops.
actor DuplicatesScanner {
    struct DuplicateGroup: Sendable, Identifiable {
        let id: UUID = UUID()
        let assetUUIDs: [UUID]
        /// Average pairwise distance; lower = more similar.
        let similarity: Float
    }

    private struct Fingerprint {
        let uuid: UUID
        let print: VNFeaturePrintObservation
    }

    /// Scans photos (thumbnails for speed) and returns groups of similar assets.
    /// `threshold`: VNFeaturePrint distance cutoff (Apple-similar ≈ < 8; bursts ≈ < 3).
    static func scan(
        db: DatabaseActor, paths: LibraryPaths,
        threshold: Float = 4.0,
        onProgress: @Sendable (Int, Int) -> Void
    ) async -> [DuplicateGroup] {
        let rows = (try? await db.query("""
            SELECT uuid FROM assets
            WHERE media_type = 'photo' AND is_deleted = 0
            ORDER BY captured_at DESC
            """)) ?? []
        let uuids = rows.compactMap { $0.text("uuid") }.compactMap(UUID.init(uuidString:))

        var prints: [Fingerprint] = []
        var done = 0
        for uuid in uuids {
            done += 1
            if done % 10 == 0 { onProgress(done, uuids.count) }
            let thumbURL = DerivativeSize.thumb.url(for: uuid, in: paths)
            guard FileManager.default.fileExists(atPath: thumbURL.path),
                  let image = ImageDecoder.downsampledImage(at: thumbURL, maxPixelSize: 288),
                  let fp = featurePrint(of: image)
            else { continue }
            prints.append(Fingerprint(uuid: uuid, print: fp))
        }

        // Union-find over similar pairs (O(n²) comparisons, fine for a few thousand).
        var parent = Dictionary(prints.map { ($0.uuid, $0.uuid) }, uniquingKeysWith: { a, _ in a })
        func find(_ x: UUID) -> UUID {
            var root = x
            while parent[root] != root { root = parent[root]! }
            return root
        }
        for i in 0..<prints.count {
            for j in (i + 1)..<prints.count {
                var distance: Float = .infinity
                try? prints[i].print.computeDistance(&distance, to: prints[j].print)
                if distance < threshold {
                    let (a, b) = (find(prints[i].uuid), find(prints[j].uuid))
                    if a != b { parent[a] = b }
                }
            }
        }
        var groups: [UUID: [UUID]] = [:]
        for fp in prints {
            groups[find(fp.uuid), default: []].append(fp.uuid)
        }
        return groups.values
            .filter { $0.count > 1 }
            .map { DuplicateGroup(assetUUIDs: $0, similarity: 0) }
            .sorted { $0.assetUUIDs.count > $1.assetUUIDs.count }
    }

    private static func featurePrint(of image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }
}
