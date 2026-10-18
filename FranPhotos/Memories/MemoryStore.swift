import CoreLocation
import Foundation

extension Memory {
    /// Decodes a row of the `memories` table (see SchemaV1).
    init?(row: SQLRow) {
        guard let uuid = UUID(uuidString: row.text("uuid") ?? ""),
              let kind = Kind(rawValue: row.text("kind") ?? "") else { return nil }
        self.uuid = uuid
        self.kind = kind
        self.title = row.text("title") ?? ""
        self.keyDate = row.date("key_date")
        let json = row.text("asset_uuids_json") ?? "[]"
        let strings = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        self.assetUUIDs = strings.compactMap { UUID(uuidString: $0) }
    }
}

/// Rule-based memory generation (On This Day, Year Highlights, Trips) with
/// results persisted to the `memories` table. Regenerates when the table is
/// empty or the last generation is older than 24 hours.
@MainActor
@Observable
final class MemoryStore {
    private(set) var memories: [Memory] = []
    /// All assets referenced by the loaded memories, keyed by UUID.
    private(set) var assetsByUUID: [UUID: Asset] = [:]
    private let db: DatabaseActor

    private static let metaKey = "memories_generated_at"
    private static let stalenessInterval: TimeInterval = 24 * 60 * 60

    init(db: DatabaseActor) {
        self.db = db
    }

    /// Assets of a memory in stored order, dropping deleted/missing ones.
    func assets(for memory: Memory) -> [Asset] {
        memory.assetUUIDs.compactMap { assetsByUUID[$0] }
    }

    /// Regenerates memories when stale, then loads them from the database.
    func loadIfNeeded() async {
        if await isStale() {
            try? await regenerate(now: Date())
        }
        await reload()
    }

    // MARK: - Persistence

    private func isStale() async -> Bool {
        let rows = (try? await db.query(
            "SELECT value FROM library_meta WHERE key = ?",
            [.text(Self.metaKey)])) ?? []
        guard let value = rows.first?.text("value"),
              let generatedAt = Double(value) else { return true }
        return Date().timeIntervalSince1970 - generatedAt > Self.stalenessInterval
    }

    private func reload() async {
        let rows = (try? await db.query("SELECT * FROM memories ORDER BY key_date DESC")) ?? []
        memories = rows.compactMap(Memory.init(row:))
        let referenced = Set(memories.flatMap(\.assetUUIDs))
        guard !referenced.isEmpty else {
            assetsByUUID = [:]
            return
        }
        let list = referenced.map { "'\($0.uuidString)'" }.joined(separator: ",")
        let assetRows = (try? await db.query(
            "SELECT * FROM assets WHERE uuid IN (\(list)) AND is_deleted = 0")) ?? []
        assetsByUUID = Dictionary(
            assetRows.map(Asset.init).map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    private func regenerate(now: Date) async throws {
        let rows = try await db.query("""
            SELECT * FROM assets
            WHERE is_deleted = 0 AND is_hidden = 0
            ORDER BY captured_at ASC
            """)
        let assets = rows.map(Asset.init)
        var generated: [Memory] = []
        generated.append(contentsOf: Self.onThisDayMemories(from: assets, now: now))
        generated.append(contentsOf: Self.yearHighlightMemories(from: assets, now: now))
        var trips = Self.tripMemories(from: assets)
        await Self.applyGeocodedTitles(to: &trips, assets: assets)
        generated.append(contentsOf: trips)

        let toStore = generated
        let metaKey = Self.metaKey
        let generatedAt = String(now.timeIntervalSince1970)
        try await db.transaction { database in
            try database.execute("DELETE FROM memories")
            for memory in toStore {
                let uuidStrings = memory.assetUUIDs.map(\.uuidString)
                let json = (try? JSONEncoder().encode(uuidStrings))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try database.execute(
                    "INSERT INTO memories (uuid, kind, title, key_date, asset_uuids_json) VALUES (?,?,?,?,?)",
                    [.text(memory.uuid.uuidString), .text(memory.kind.rawValue),
                     .text(memory.title),
                     memory.keyDate.map { SQLValue.date($0) } ?? .null,
                     .text(json)])
            }
            try database.execute(
                "INSERT INTO library_meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                [.text(metaKey), .text(generatedAt)])
        }
    }

    // MARK: - Generation rules

    /// "On This Day": assets captured on today's month-day, one memory per
    /// past year.
    static func onThisDayMemories(from assets: [Asset], now: Date) -> [Memory] {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.dateComponents([.year, .month, .day], from: now)
        guard let thisYear = today.year, let month = today.month, let day = today.day else {
            return []
        }
        var byYear: [Int: [Asset]] = [:]
        for asset in assets {
            let comps = cal.dateComponents([.year, .month, .day], from: asset.capturedAt)
            guard comps.month == month, comps.day == day,
                  let year = comps.year, year < thisYear else { continue }
            byYear[year, default: []].append(asset)
        }
        return byYear.keys.sorted(by: >).map { year in
            Memory(uuid: UUID(), kind: .onThisDay,
                   title: String(localized: "On This Day"),
                   keyDate: cal.date(from: DateComponents(year: year, month: month, day: day)),
                   assetUUIDs: (byYear[year] ?? [])
                    .sorted { $0.capturedAt < $1.capturedAt }
                    .map(\.uuid))
        }
    }

    /// "Year Highlights": per past year, the top 12 assets ranked by
    /// favorite/edit/location score, newest first on ties.
    static func yearHighlightMemories(from assets: [Asset], now: Date) -> [Memory] {
        let cal = Calendar(identifier: .gregorian)
        let thisYear = cal.component(.year, from: now)
        var byYear: [Int: [Asset]] = [:]
        for asset in assets {
            let year = cal.component(.year, from: asset.capturedAt)
            guard year < thisYear else { continue }
            byYear[year, default: []].append(asset)
        }
        return byYear.keys.sorted(by: >).compactMap { year in
            let ranked = (byYear[year] ?? []).sorted { a, b in
                let scoreA = score(a), scoreB = score(b)
                return scoreA != scoreB ? scoreA > scoreB : a.capturedAt > b.capturedAt
            }
            let top = Array(ranked.prefix(12))
            guard !top.isEmpty else { return nil }
            return Memory(uuid: UUID(), kind: .yearHighlight,
                          title: String(localized: "\(year) Highlights"),
                          keyDate: cal.date(from: DateComponents(year: year, month: 12, day: 31)),
                          assetUUIDs: top.map(\.uuid))
        }
    }

    /// Highlight score: favorite weighs most, then edits, then geo tag.
    private static func score(_ asset: Asset) -> Int {
        (asset.isFavorite ? 2 : 0)
            + (asset.editVersion > 0 ? 1 : 0)
            + (asset.latitude != nil ? 1 : 0)
    }

    /// "Trips": runs of consecutive days (gap ≤ 2 days) whose assets share a
    /// rounded 1° lat/lon cell. A trip needs ≥ 3 assets spanning ≥ 2 days.
    static func tripMemories(from assets: [Asset]) -> [Memory] {
        struct Cell: Hashable { let lat: Int; let lon: Int }
        var byCell: [Cell: [Asset]] = [:]
        for asset in assets {
            guard let lat = asset.latitude, let lon = asset.longitude else { continue }
            let cell = Cell(lat: Int(lat.rounded()), lon: Int(lon.rounded()))
            byCell[cell, default: []].append(asset)
        }
        let maxGap: TimeInterval = 2 * 24 * 60 * 60
        var trips: [Memory] = []
        for (_, cellAssets) in byCell {
            let sorted = cellAssets.sorted { $0.capturedAt < $1.capturedAt }
            var run: [Asset] = []
            for asset in sorted {
                if let last = run.last,
                   asset.capturedAt.timeIntervalSince(last.capturedAt) > maxGap {
                    appendTrip(run, to: &trips)
                    run = []
                }
                run.append(asset)
            }
            appendTrip(run, to: &trips)
        }
        return trips.sorted { ($0.keyDate ?? .distantPast) > ($1.keyDate ?? .distantPast) }
    }

    private static func appendTrip(_ run: [Asset], to trips: inout [Memory]) {
        let cal = Calendar(identifier: .gregorian)
        let days = Set(run.map { cal.startOfDay(for: $0.capturedAt) })
        guard run.count >= 3, days.count >= 2 else { return }
        trips.append(Memory(uuid: UUID(), kind: .trip,
                            title: String(localized: "Trip"),
                            keyDate: run.first?.capturedAt,
                            assetUUIDs: run.map(\.uuid)))
    }

    // MARK: - Reverse-geocoded trip titles

    /// Replaces generic "Trip" titles with the trip's locality name (Apple
    /// Photos style: just the place, e.g. "Nanjing" / "南京"). Best-effort:
    /// offline or rate-limited runs keep the generic title. Serialized with a
    /// small pause because CLGeocoder rate-limits aggressive callers.
    static func applyGeocodedTitles(to trips: inout [Memory], assets: [Asset]) async {
        let assetsByID = Dictionary(assets.map { ($0.uuid, $0) },
                                    uniquingKeysWith: { first, _ in first })
        for index in trips.indices {
            let coords: [(lat: Double, lon: Double)] = trips[index].assetUUIDs
                .compactMap { assetsByID[$0] }
                .compactMap { asset in
                    guard let lat = asset.latitude, let lon = asset.longitude
                    else { return nil }
                    return (lat, lon)
                }
            guard !coords.isEmpty else { continue }
            let meanLat = coords.map(\.lat).reduce(0, +) / Double(coords.count)
            let meanLon = coords.map(\.lon).reduce(0, +) / Double(coords.count)
            if let name = await reverseGeocodeLocality(latitude: meanLat,
                                                       longitude: meanLon) {
                trips[index].title = name
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// One reverse-geocode lookup with a 5 s timeout; returns the finest
    /// usable administrative name.
    static func reverseGeocodeLocality(latitude: Double,
                                       longitude: Double) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let location = CLLocation(latitude: latitude, longitude: longitude)
                guard let placemarks = try? await CLGeocoder()
                    .reverseGeocodeLocation(location) else { return nil }
                let pm = placemarks.first
                return pm?.locality ?? pm?.subAdministrativeArea
                    ?? pm?.administrativeArea ?? pm?.name
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
}
