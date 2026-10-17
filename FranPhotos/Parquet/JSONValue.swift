import Foundation

/// Sendable JSON value used at actor boundaries (fpparquet bridge protocol).
indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Converts JSONSerialization output ([String: Any] with NSNumber/NSNull) to JSONValue.
    static func from(any value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let b as Bool:
            return .bool(b)
        case let n as NSNumber:
            // NSNumber bridges both; distinguish integers from doubles by CFType.
            if CFNumberIsFloatType(n as CFNumber) {
                return .double(n.doubleValue)
            }
            return .int(n.int64Value)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map(JSONValue.from(any:)))
        case let o as [String: Any]:
            return .object(o.mapValues(JSONValue.from(any:)))
        default:
            return .null
        }
    }

    /// Converts back to JSONSerialization-compatible Foundation objects.
    var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .int(let n): n
        case .double(let d): d
        case .string(let s): s
        case .array(let a): a.map(\.anyValue)
        case .object(let o): o.mapValues(\.anyValue)
        }
    }

    // Accessors
    var stringValue: String? {
        if case .string(let s) = self { s } else { nil }
    }

    var intValue: Int64? {
        switch self {
        case .int(let n): n
        case .double(let d): Int64(d)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): d
        case .int(let n): Double(n)
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .int(let n): n != 0
        default: nil
        }
    }
}
