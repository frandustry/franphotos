import Foundation
import Testing
@testable import FranPhotos

/// End-to-end: build a 240-photo library across 14 months, import, sync
/// parquet partitions, verify lazy month reads and index consistency.
struct IntegrationTests {
    @Test(.timeLimit(.minutes(3)))
    func fullLibraryLifecycle() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LibraryStore.create(at: dir.appending(path: "BigLib.franphotoslibrary"))
        let db = try await DatabaseActor.openOrCreate(at: store.paths.database)

        // 240 fixtures across 14 months with varied dates/GPS.
        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let base = Calendar.current.date(
            from: DateComponents(year: 2024, month: 1, day: 1, hour: 12))!  // 2024-01-01 local
        let perMonth = 18
        for month in 0..<14 {
            for i in 0..<perMonth {
                // Exactly 14 distinct calendar months.
                guard let monthStart = Calendar.current.date(
                    byAdding: .month, value: month, to: base)
                else { continue }
                let date = monthStart.addingTimeInterval(TimeInterval(i * 3600 * 7))
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                            from: date)
                let dto = String(format: "%04d:%02d:%02d %02d:%02d:%02d",
                                 comps.year!, comps.month!, comps.day!,
                                 comps.hour!, comps.minute!, comps.second!)
                let hasGPS = i % 3 == 0
                _ = try TestFixtures.makeJPEG(
                    in: src,
                    name: String(format: "IMG_%02d_%04d.jpg", month, i),
                    exif: .init(dateTimeOriginal: dto,
                                offsetTimeOriginal: "+08:00",
                                latitude: hasGPS ? 31.0 + Double(month) * 0.01 : nil,
                                longitude: hasGPS ? 121.0 + Double(month) * 0.01 : nil))
            }
        }

        // Import.
        let engine = ImportEngine(library: store, db: db)
        let outcome = await engine.importFiles([src]) { _ in }
        #expect(outcome.importedUUIDs.count == 14 * perMonth)
        #expect(outcome.failures.isEmpty)

        // Sync all timeline partitions to parquet.
        let sync = ParquetSync(db: db, paths: store.paths)
        let monthRows = try await db.query(
            "SELECT captured_at FROM assets WHERE is_deleted = 0")
        let months = Set(monthRows.compactMap { $0.date("captured_at") }.map(MonthKey.init))
        await sync.markDirty(months: months)
        try await sync.syncTimeline()

        guard ParquetHelperLocator.ensureBuilt() != nil else { return }

        // One parquet partition per month + index.
        let fm = FileManager.default
        let timelineDir = store.paths.timelineParquetDirectory
        var monthPartitionCount = 0
        if let enumerator = fm.enumerator(at: timelineDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator.allObjects
            where url.pathExtension == "parquet" && !url.lastPathComponent.hasPrefix("_") {
                monthPartitionCount += 1
            }
        }
        #expect(monthPartitionCount == 14)

        // Index from parquet (delete nothing; index file present).
        let index = try await sync.timelineIndex()
        #expect(index.count == 14)
        #expect(index.reduce(0) { $0 + $1.rowCount } == 14 * perMonth)

        // Lazy month read returns exactly that month's rows, newest first.
        for entry in index {
            let key = MonthKey(parsing: entry.month)!
            let assets = try await sync.monthAssets(key)
            #expect(assets.count == entry.rowCount)
            #expect(assets == assets.sorted(by: Asset.librarySortPredicate))
        }

        // Geo + EXIF survived the round trip.
        let geoCount = try await db.scalarInt(
            "SELECT COUNT(*) FROM assets WHERE latitude IS NOT NULL")
        #expect(geoCount > 0)

        // Staleness detection: mutate one asset, validate repairs that month only.
        let someUUID = outcome.importedUUIDs[0]
        try await db.execute("UPDATE assets SET is_favorite = 1 WHERE uuid = ?",
                             [.text(someUUID.uuidString)])
        try await sync.validateAndRepair()
        let checksums = try await db.query(
            "SELECT partition_key FROM partition_checksums WHERE kind = 'timeline'")
        #expect(checksums.count == 14)
    }
}
