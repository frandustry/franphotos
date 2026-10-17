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

    init(key: MonthKey) { self.key = key }

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
    private var hotOrder: [MonthKey] = []  // most-recently-used last
    let maxHotSlices = 3

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

    func slice(for key: MonthKey) -> MonthSlice {
        if let existing = slices[key] {
            touch(key)
            return existing
        }
        let slice = MonthSlice(key: key)
        slices[key] = slice
        touch(key)
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
        }
    }

    func invalidate() async {
        slices.removeAll()
        hotOrder.removeAll()
        await loadIndex()
    }

    // MARK: - LRU

    private func touch(_ key: MonthKey) {
        hotOrder.removeAll { $0 == key }
        hotOrder.append(key)
        while hotOrder.count > maxHotSlices {
            let evict = hotOrder.removeFirst()
            slices.removeValue(forKey: evict)
        }
    }
}
