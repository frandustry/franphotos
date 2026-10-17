import Foundation

/// "2025-03" — partition key for timeline parquet files and UI sections.
struct MonthKey: Sendable, Hashable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(_ date: Date) {
        let cal = Calendar(identifier: .gregorian)
        year = cal.component(.year, from: date)
        month = cal.component(.month, from: date)
    }

    init?(parsing string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]),
              (1...12).contains(m) else { return nil }
        year = y
        month = m
    }

    var description: String { String(format: "%04d-%02d", year, month) }

    var parquetPartitionKey: String { "timeline:\(description)" }

    static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    /// Newest first.
    static func descending(_ a: MonthKey, _ b: MonthKey) -> Bool { b < a }

    /// Localized display name like "March 2025" / "2025年3月".
    ///
    /// Creating a DateFormatter is extremely expensive (ICU `udat_open` showed
    /// up as the heaviest stack in a hang trace: every grid re-render called
    /// this getter once per section header), so results are memoized per key
    /// and invalidated when the locale changes.
    var displayName: String {
        Self.displayNameCache.value(for: self)
    }

    private static let displayNameCache = DisplayNameCache()

    private final class DisplayNameCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MonthKey: String] = [:]
        private var localeID: String = ""

        func value(for key: MonthKey) -> String {
            lock.lock()
            defer { lock.unlock() }
            let currentLocaleID = Locale.current.identifier
            if currentLocaleID != localeID {
                values.removeAll()
                localeID = currentLocaleID
            }
            if let cached = values[key] { return cached }
            var comps = DateComponents()
            comps.year = key.year
            comps.month = key.month
            let date = Calendar(identifier: .gregorian).date(from: comps) ?? Date()
            let fmt = DateFormatter()
            fmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "yyyyMMMM", options: 0,
                                                      locale: .current)
            let name = fmt.string(from: date)
            values[key] = name
            return name
        }
    }
}
