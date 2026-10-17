import Foundation
import Testing
@testable import FranPhotos

/// Regression tests for the grid-hang fix: the timeline LRU must never mutate
/// observed state from the read path (`slice(for:)`), and eviction must clear
/// rows while keeping slice identity so on-screen sections auto-reload.
@MainActor
struct TimelineStoreTests {
    /// Builds a library with one photo in each of `monthCount` consecutive months.
    private func makeStore(monthCount: Int) async throws -> (TimelineStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let library = try LibraryStore.create(at: dir.appending(path: "TL.franphotoslibrary"))
        let src = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let base = Calendar.current.date(
            from: DateComponents(year: 2024, month: 1, day: 15, hour: 12))!
        for month in 0..<monthCount {
            let date = Calendar.current.date(byAdding: .month, value: month, to: base)!
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            let dto = String(format: "%04d:%02d:%02d %02d:%02d:%02d",
                             comps.year!, comps.month!, comps.day!,
                             comps.hour!, comps.minute!, comps.second!)
            _ = try TestFixtures.makeJPEG(
                in: src, name: String(format: "IMG_%02d.jpg", month),
                exif: .init(dateTimeOriginal: dto, offsetTimeOriginal: "+08:00",
                            latitude: nil, longitude: nil))
        }
        let db = try await DatabaseActor.openOrCreate(at: library.paths.database)
        let engine = ImportEngine(library: library, db: db)
        _ = await engine.importFiles([src]) { _ in }
        let sync = ParquetSync(db: db, paths: library.paths)
        let rows = try await db.query("SELECT captured_at FROM assets")
        await sync.markDirty(
            months: Set(rows.compactMap { $0.date("captured_at") }.map(MonthKey.init)))
        try await sync.syncTimeline()
        let store = TimelineStore(sync: sync)
        await store.loadIndex()
        return (store, dir)
    }

    @Test(.timeLimit(.minutes(2)))
    func sliceLookupIsPureAndEvictionKeepsIdentity() async throws {
        let monthCount = 14  // > maxHotSlices (12) so eviction must kick in
        let (store, dir) = try await makeStore(monthCount: monthCount)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(store.months.count == monthCount)
        let keys = store.months.map(\.key)  // newest first

        // Slices are pre-created for every indexed month: lookup returns the
        // same instance and never has side effects.
        let newestSlice = store.slice(for: keys[0])
        #expect(store.slice(for: keys[0]) === newestSlice)
        #expect(!newestSlice.isLoaded)
        let newestInitialToken = newestSlice.reloadToken

        // Load every month, newest first; only the 12 most-recently-used stay hot.
        for key in keys {
            await store.ensureLoaded(key)
        }
        let loaded = keys.map { store.slice(for: $0) }.filter(\.isLoaded)
        #expect(loaded.count == store.maxHotSlices)

        // The two oldest-loaded months were evicted: rows cleared, identity kept,
        // reload token bumped (so an on-screen section schedules a reload).
        let evicted = store.slice(for: keys[0])
        #expect(!evicted.isLoaded)
        #expect(evicted.assets.isEmpty)
        #expect(evicted.reloadToken != newestInitialToken)
        #expect(store.slice(for: keys[0]) === evicted)

        // Reloading an evicted slice works (self-heal for on-screen sections).
        await store.ensureLoaded(keys[0])
        #expect(store.slice(for: keys[0]).isLoaded)
        #expect(store.slice(for: keys[0]).assets.count == 1)

        // Pure reads must not change load state anywhere.
        let loadedBefore = keys.map { store.slice(for: $0).isLoaded }
        for key in keys { _ = store.slice(for: key) }
        #expect(keys.map { store.slice(for: $0).isLoaded } == loadedBefore)
    }

    @Test
    func displayNameIsStableAndLocalized() {
        let key = MonthKey(year: 2025, month: 3)
        let first = key.displayName
        #expect(!first.isEmpty)
        #expect(first == key.displayName)  // memoized, deterministic
        #expect(MonthKey(year: 2024, month: 12).displayName != first)
    }
}
