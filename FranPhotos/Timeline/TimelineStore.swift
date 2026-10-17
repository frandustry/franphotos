import Foundation
import SwiftUI

/// One month of timeline rows, loaded on demand from its parquet partition
/// (SQLite fallback handled inside ParquetSync).
@MainActor
@Observable
final class MonthSlice: Identifiable {
    let key: MonthKey
    var assets: [Asset] = []
    var isLoaded = false
    var isLoading = false
    /// Bumped (store-wide monotonic) whenever the slice is evicted/recreated, so
    /// views keyed on it restart their load task instead of showing stale emptiness.
    var reloadToken: Int

    init(key: MonthKey, reloadToken: Int) {
        self.key = key
        self.reloadToken = reloadToken
    }

    nonisolated var id: String { key.description }

    /// Day sub-groups within this month (for the Days zoom level), newest first.
    var dayGroups: [(day: Date, assets: [Asset])] {
        let cal = Calendar.current
        var groups: [Date: [Asset]] = [:]
        var order: [Date] = []
        for asset in assets {
            let day = cal.startOfDay(for: asset.capturedAt)
            if groups[day] == nil {
                groups[day] = []
                order.append(day)
            }
            groups[day]?.append(asset)
        }
        return order.sorted(by: >).map { (day: $0, assets: groups[$0] ?? []) }
    }
}

/// Timeline presentation model: month index (from `_index.parquet` via ParquetSync)
/// plus an LRU pool of loaded month slices — at most `maxHotSlices` stay in memory.
///
/// Important: `slice(for:)` never mutates anything. Mutating observed state from
/// a view-body read (the old LRU "touch" did exactly that, and evicted after just
/// 3 hot slices) put SwiftUI's AttributeGraph into a perpetual invalidation loop
/// and hung the app whenever more than a few month sections were on screen. All
/// LRU bookkeeping happens in `ensureLoaded`, i.e. from async work, never during
/// view evaluation.
@MainActor
@Observable
final class TimelineStore {
    struct MonthSummary: Identifiable, Hashable {
        let key: MonthKey
        let count: Int
        let coverUUID: UUID?
        var id: String { key.description }
    }

    struct YearSummary: Identifiable, Hashable {
        let year: Int
        let monthCount: Int
        let assetCount: Int
        let coverUUID: UUID?
        var id: Int { year }
    }

    enum Zoom: String, CaseIterable, Sendable {
        case years, months, days, allPhotos

        var localizedName: String {
            switch self {
            case .years: String(localized: "Years")
            case .months: String(localized: "Months")
            case .days: String(localized: "Days")
            case .allPhotos: String(localized: "All Photos")
            }
        }
    }

    private(set) var months: [MonthSummary] = []
    private(set) var years: [YearSummary] = []
    var zoom: Zoom = .allPhotos

    private var slices: [MonthKey: MonthSlice] = [:]
    /// Loaded slice keys, most-recently-used last. Only mutated by `ensureLoaded`.
    private var hotOrder: [MonthKey] = []
    /// A screen can easily show 6–10 month sections at small thumbnail sizes.
    let maxHotSlices = 12

    private var reloadTokenCounter = 0

    private let sync: ParquetSync

    init(sync: ParquetSync) {
        self.sync = sync
    }

    /// Loads the timeline index (parquet-first, SQLite fallback inside ParquetSync).
    func loadIndex() async {
        let entries = (try? await sync.timelineIndex()) ?? []
        months = entries.map { entry in
            MonthSummary(key: MonthKey(parsing: entry.month) ?? MonthKey(year: 1970, month: 1),
                         count: entry.rowCount,
                         coverUUID: UUID(uuidString: entry.coverUUID))
        }
        // Pre-create slice objects so view bodies never trigger a dictionary
        // mutation via `slice(for:)` — reads must stay side-effect free.
        for month in months where slices[month.key] == nil {
            slices[month.key] = MonthSlice(key: month.key, reloadToken: nextReloadToken())
        }
        var yearMap: [Int: (monthCount: Int, assetCount: Int, cover: UUID?)] = [:]
        for m in months {
            var agg = yearMap[m.key.year] ?? (0, 0, nil)
            agg.monthCount += 1
            agg.assetCount += m.count
            if agg.cover == nil { agg.cover = m.coverUUID }
            yearMap[m.key.year] = agg
        }
        years = yearMap.keys.sorted(by: >).map { year in
            let agg = yearMap[year]!
            return YearSummary(year: year, monthCount: agg.monthCount,
                               assetCount: agg.assetCount, coverUUID: agg.cover)
        }
    }

    /// Pure lookup (plus a defensive create for keys missing from the index).
    /// Deliberately does NOT touch LRU state — see the type's doc comment.
    func slice(for key: MonthKey) -> MonthSlice {
        if let existing = slices[key] {
            return existing
        }
        let slice = MonthSlice(key: key, reloadToken: nextReloadToken())
        slices[key] = slice
        return slice
    }

    /// Ensures a month's rows are loaded (from parquet via ParquetSync).
    func ensureLoaded(_ key: MonthKey) async {
        let slice = slice(for: key)
        guard !slice.isLoaded, !slice.isLoading else { return }
        slice.isLoading = true
        defer { slice.isLoading = false }
        if let assets = try? await sync.monthAssets(key) {
            // Never show hidden/deleted in the main timeline.
            slice.assets = assets.filter { !$0.isHidden && !$0.isDeleted }
            slice.isLoaded = true
            markRecentlyUsed(key)
        }
    }

    func invalidate() async {
        slices.removeAll()
        hotOrder.removeAll()
        await loadIndex()
    }

    /// Replaces an asset in any loaded slice; removes it when it became
    /// hidden/deleted (the main timeline never shows those).
    func updateAssetInSlices(_ asset: Asset) {
        let key = MonthKey(asset.capturedAt)
        guard let slice = slices[key], slice.isLoaded else { return }
        if asset.isHidden || asset.isDeleted {
            slice.assets.removeAll { $0.id == asset.id }
        } else if let index = slice.assets.firstIndex(where: { $0.id == asset.id }) {
            slice.assets[index] = asset
            slice.assets.sort(by: Asset.librarySortPredicate)
        }
    }

    func removeFromSlices(_ uuid: UUID) {
        for slice in slices.values {
            slice.assets.removeAll { $0.id == uuid }
        }
    }

    /// Neighbor navigation for the detail browser, crossing month boundaries
    /// (loads the adjacent slice from parquet when needed).
    func neighbor(of asset: Asset, direction: Int) async -> Asset? {
        let key = MonthKey(asset.capturedAt)
        await ensureLoaded(key)
        let currentSlice = slice(for: key)
        if let index = currentSlice.assets.firstIndex(where: { $0.id == asset.id }) {
            let target = index + direction
            if currentSlice.assets.indices.contains(target) {
                return currentSlice.assets[target]
            }
        }
        // Cross the month boundary.
        guard let monthIndex = months.firstIndex(where: { $0.key == key }) else { return nil }
        let neighborMonth = months[safe: monthIndex - direction]  // months sorted desc
        guard let neighborMonth else { return nil }
        await ensureLoaded(neighborMonth.key)
        let assets = slice(for: neighborMonth.key).assets
        return direction > 0 ? assets.last : assets.first
    }

    // MARK: - LRU

    /// Called only from `ensureLoaded` (async work, never view evaluation).
    private func markRecentlyUsed(_ key: MonthKey) {
        hotOrder.removeAll { $0 == key }
        hotOrder.append(key)
        evictIfNeeded()
    }

    /// Evicts least-recently-used *loaded* slices by clearing their rows. Slice
    /// object identity is kept (the dictionary stays stable for observers) and
    /// `reloadToken` is bumped so affected sections schedule a reload.
    private func evictIfNeeded() {
        while hotOrder.count > maxHotSlices {
            guard let victim = hotOrder.first(where: { key in
                guard let slice = slices[key] else { return true }  // stale entry
                return slice.isLoaded && !slice.isLoading
            }) else { return }
            hotOrder.removeAll { $0 == victim }
            if let slice = slices[victim], slice.isLoaded {
                slice.assets = []
                slice.isLoaded = false
                slice.reloadToken = nextReloadToken()
            }
        }
    }

    private func nextReloadToken() -> Int {
        reloadTokenCounter += 1
        return reloadTokenCounter
    }
}
