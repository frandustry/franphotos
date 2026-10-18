import Foundation
import Testing
@testable import FranPhotos

/// Unit tests for the rule-based memory generation (geocoding is network-bound
/// and therefore not exercised here — trips fall back to the generic title).
@MainActor
struct MemoryStoreTests {
    private func makeAsset(capturedAt: Date, latitude: Double? = nil,
                           longitude: Double? = nil,
                           isFavorite: Bool = false, editVersion: Int = 0) -> Asset {
        let uuid = UUID()
        return Asset(
            uuid: uuid, mediaType: .photo, capturedAt: capturedAt, capturedAtTZOffset: nil,
            addedAt: Date(), durationMs: nil,
            width: 100, height: 100, fileSize: 100, sha256: uuid.uuidString,
            originalRelpath: "originals/x/\(uuid).jpg", filename: "\(uuid).jpg", uti: nil,
            title: nil, caption: nil,
            isFavorite: isFavorite, isHidden: false, isDeleted: false, deletedAt: nil,
            rating: 0, cameraMake: nil, cameraModel: nil, lensModel: nil, iso: nil,
            aperture: nil, shutterSpeed: nil, focalLength: nil,
            latitude: latitude, longitude: longitude, altitude: nil,
            hdrType: .sdr, isLivePhoto: false, livePhotoVideoRelpath: nil,
            livePhotoStillTimeMs: nil, videoCodec: nil, colorSpace: nil,
            hasAudio: nil, frameRate: nil, editRecipeJSON: nil, editVersion: editVersion)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func onThisDayGroupsByPastYear() {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.month, .day], from: now)
        let thisYear = cal.component(.year, from: now)
        let assets = [
            makeAsset(capturedAt: date(thisYear - 2, comps.month!, comps.day!)),
            makeAsset(capturedAt: date(thisYear - 1, comps.month!, comps.day!)),
            makeAsset(capturedAt: now),  // this year is excluded
            makeAsset(capturedAt: date(thisYear - 1, comps.month!, comps.day! + 1)),  // wrong day
        ]
        let memories = MemoryStore.onThisDayMemories(from: assets, now: now)
        #expect(memories.count == 2)
        #expect(memories.allSatisfy { $0.kind == .onThisDay })
        #expect(memories[0].assetUUIDs.count == 1)
    }

    @Test func yearHighlightsRanksAndCaps() {
        let cal = Calendar(identifier: .gregorian)
        let thisYear = cal.component(.year, from: Date())
        var assets: [Asset] = []
        // 15 plain assets + 2 favorites in the past year → 12 picked, favorites first.
        for i in 0..<15 {
            assets.append(makeAsset(
                capturedAt: date(thisYear - 1, 6, min(28, i + 1))))
        }
        let fav = makeAsset(capturedAt: date(thisYear - 1, 6, 1), isFavorite: true)
        assets.append(fav)
        assets.append(makeAsset(capturedAt: Date()))  // current year excluded
        let memories = MemoryStore.yearHighlightMemories(from: assets, now: Date())
        #expect(memories.count == 1)
        let memory = memories[0]
        #expect(memory.kind == .yearHighlight)
        #expect(memory.assetUUIDs.count == 12)
        #expect(memory.assetUUIDs.first == fav.uuid)  // favorite outranks
    }

    @Test func tripDetectionThresholdsAndSplitting() {
        // A 3-day run in one place → a trip.
        var run: [Asset] = []
        for day in 1...3 {
            run.append(makeAsset(capturedAt: date(2024, 5, day),
                                 latitude: 32.06, longitude: 118.80))
        }
        #expect(MemoryStore.tripMemories(from: run).count == 1)

        // Fewer than 3 assets → no trip.
        #expect(MemoryStore.tripMemories(from: Array(run.prefix(2))).isEmpty)

        // All 3 on one day → needs ≥ 2 distinct days.
        let sameDay = (0..<3).map { _ in
            makeAsset(capturedAt: date(2024, 5, 1), latitude: 32.06, longitude: 118.80)
        }
        #expect(MemoryStore.tripMemories(from: sameDay).isEmpty)

        // A gap > 2 days splits one run into two (each too short → no trips).
        let split = [run[0], run[1],
                     makeAsset(capturedAt: date(2024, 5, 10),
                               latitude: 32.06, longitude: 118.80)]
        #expect(MemoryStore.tripMemories(from: split).isEmpty)

        // A different 1° cell forms a separate trip.
        let elsewhere = (1...3).map {
            makeAsset(capturedAt: date(2024, 6, $0), latitude: 31.23, longitude: 121.47)
        }
        #expect(MemoryStore.tripMemories(from: run + elsewhere).count == 2)

        // Assets without coordinates never form trips.
        #expect(MemoryStore.tripMemories(from: [makeAsset(capturedAt: date(2024, 1, 1)),
                                                makeAsset(capturedAt: date(2024, 1, 2)),
                                                makeAsset(capturedAt: date(2024, 1, 3))]).isEmpty)
    }
}
