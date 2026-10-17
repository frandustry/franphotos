import Foundation

/// `library.json` at the bundle root. The manifest is the single source of truth
/// for library identity and format versioning. It is tiny and human-readable so a
/// library can be inspected and repaired with any text editor.
struct LibraryManifest: Codable, Sendable, Equatable {
    /// Bundle format version. Bumped when the on-disk layout changes.
    var formatVersion: Int
    /// Stable identity of this library, used in parquet files and exports.
    var libraryUUID: UUID
    /// User-facing library name (defaults to the bundle file name).
    var name: String
    var createdAt: Date
    /// Version of the app that created / last migrated the library.
    var appVersion: String
    /// SQLite schema version (matches latest applied migration).
    var schemaVersion: Int

    static let currentFormatVersion = 1
    static let currentSchemaVersion = 1

    static func fresh(name: String, appVersion: String) -> LibraryManifest {
        // ISO8601 encoding has second precision; truncate so encode/decode round-trips losslessly.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return LibraryManifest(
            formatVersion: currentFormatVersion,
            libraryUUID: UUID(),
            name: name,
            createdAt: now,
            appVersion: appVersion,
            schemaVersion: currentSchemaVersion
        )
    }

    static var jsonEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var jsonDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
