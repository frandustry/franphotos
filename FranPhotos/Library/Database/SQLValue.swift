import Foundation

/// A typed SQLite value, used both for parameter binding and result rows.
enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func bool(_ b: Bool) -> SQLValue { .integer(b ? 1 : 0) }

    var intValue: Int64? {
        switch self {
        case .integer(let v): v
        case .double(let v): Int64(v)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): v
        case .integer(let v): Double(v)
        default: nil
        }
    }

    var textValue: String? {
        if case .text(let v) = self { v } else { nil }
    }

    var boolValue: Bool? { intValue.map { $0 != 0 } }

    var dateValue: Date? { doubleValue.map { Date(timeIntervalSince1970: $0) } }

    static func date(_ d: Date) -> SQLValue { .double(d.timeIntervalSince1970) }

    static func optionalText(_ s: String?) -> SQLValue {
        s.map { .text($0) } ?? .null
    }
}

/// One result row: values by column name, preserving column order.
struct SQLRow: Sendable {
    let columns: [String]
    let values: [SQLValue]
    private let index: [String: Int]

    init(columns: [String], values: [SQLValue]) {
        self.columns = columns
        self.values = values
        var idx: [String: Int] = [:]
        for (i, c) in columns.enumerated() where idx[c] == nil {
            idx[c] = i
        }
        self.index = idx
    }

    subscript(_ column: String) -> SQLValue {
        guard let i = index[column] else { return .null }
        return values[i]
    }

    func text(_ column: String) -> String? { self[column].textValue }
    func int(_ column: String) -> Int64? { self[column].intValue }
    func double(_ column: String) -> Double? { self[column].doubleValue }
    func bool(_ column: String) -> Bool { self[column].boolValue ?? false }
    func date(_ column: String) -> Date? { self[column].dateValue }
}
