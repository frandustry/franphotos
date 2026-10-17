import Foundation

/// Smart album rule set: stored as JSON in `albums.smart_rules_json`,
/// compiled to a SQL WHERE clause (with bound parameters, no string injection).
struct SmartRuleSet: Codable, Sendable, Equatable {
    var match: Match = .all
    var conditions: [Condition] = []

    enum Match: String, Codable, Sendable, CaseIterable {
        case all, any
        var sqlJoiner: String { self == .all ? " AND " : " OR " }
        var localizedName: String {
            self == .all ? String(localized: "all") : String(localized: "any")
        }
    }

    struct Condition: Codable, Sendable, Equatable, Identifiable {
        var id: UUID = UUID()
        var field: Field
        var op: Op
        var value: String = ""

        enum Field: String, Codable, Sendable, CaseIterable {
            case mediaType, isFavorite, isLivePhoto, hdrType, cameraModel
            case keyword, filename, hasLocation, capturedAfter, capturedBefore

            var localizedName: String {
                switch self {
                case .mediaType: String(localized: "Media Type")
                case .isFavorite: String(localized: "Favorite")
                case .isLivePhoto: String(localized: "Live Photo")
                case .hdrType: String(localized: "HDR Type")
                case .cameraModel: String(localized: "Camera Model")
                case .keyword: String(localized: "Keyword")
                case .filename: String(localized: "Filename")
                case .hasLocation: String(localized: "Has Location")
                case .capturedAfter: String(localized: "Captured After")
                case .capturedBefore: String(localized: "Captured Before")
                }
            }
        }

        enum Op: String, Codable, Sendable, CaseIterable {
            case isEqual, isNotEqual, contains, after, before, exists

            var localizedName: String {
                switch self {
                case .isEqual: String(localized: "is")
                case .isNotEqual: String(localized: "is not")
                case .contains: String(localized: "contains")
                case .after: String(localized: "after")
                case .before: String(localized: "before")
                case .exists: String(localized: "exists")
                }
            }
        }

        /// Suggested operators per field.
        static func ops(for field: Field) -> [Op] {
            switch field {
            case .mediaType, .isFavorite, .isLivePhoto, .hdrType:
                [.isEqual, .isNotEqual]
            case .cameraModel, .keyword, .filename:
                [.contains, .isEqual, .isNotEqual]
            case .hasLocation:
                [.exists]
            case .capturedAfter:
                [.after]
            case .capturedBefore:
                [.before]
            }
        }

        static func valueOptions(for field: Field) -> [String]? {
            switch field {
            case .mediaType: ["photo", "video"]
            case .isFavorite, .isLivePhoto, .hasLocation: ["1", "0"]
            case .hdrType: HDRType.allCases.map(\.rawValue)
            default: nil
            }
        }
    }

    /// Compiles to SQL. Always safe: values are bound parameters.
    func sqlWhere() -> (sql: String, bindings: [SQLValue]) {
        var parts: [String] = []
        var bindings: [SQLValue] = []
        for condition in conditions {
            guard let fragment = Self.sqlFragment(for: condition) else { continue }
            parts.append(fragment.sql)
            bindings.append(contentsOf: fragment.bindings)
        }
        if parts.isEmpty {
            return ("1 = 1", [])
        }
        return ("(" + parts.joined(separator: match.sqlJoiner) + ")", bindings)
    }

    private static func sqlFragment(for c: Condition) -> (sql: String, bindings: [SQLValue])? {
        let negate = c.op == .isNotEqual
        switch c.field {
        case .mediaType:
            return ("media_type = ?", [.text(c.value)])
        case .isFavorite:
            return ("is_favorite = ?", [.bool(c.value == "1" || c.value == "true")])
        case .isLivePhoto:
            return ("is_live_photo = ?", [.bool(c.value == "1" || c.value == "true")])
        case .hdrType:
            return ("hdr_type = ?", [.text(c.value)])
        case .cameraModel:
            switch c.op {
            case .contains:
                return ("camera_model LIKE ?", [.text("%\(c.value)%")])
            case .isNotEqual:
                return ("(camera_model IS NULL OR camera_model != ?)", [.text(c.value)])
            default:
                return ("camera_model = ?", [.text(c.value)])
            }
        case .filename:
            return ("filename LIKE ?", [.text("%\(c.value)%")])
        case .keyword:
            let sql = """
            EXISTS (SELECT 1 FROM asset_keywords ak JOIN keywords k ON k.uuid = ak.keyword_uuid
                    WHERE ak.asset_uuid = assets.uuid AND k.name LIKE ?)
            """
            if negate {
                return ("NOT \(sql)", [.text(c.value)])
            }
            return (sql, [.text(c.value)])
        case .hasLocation:
            return ("latitude IS NOT NULL AND longitude IS NOT NULL", [])
        case .capturedAfter:
            guard let date = Self.parseDate(c.value) else { return nil }
            return ("captured_at >= ?", [.date(date)])
        case .capturedBefore:
            guard let date = Self.parseDate(c.value) else { return nil }
            return ("captured_at <= ?", [.date(date)])
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
