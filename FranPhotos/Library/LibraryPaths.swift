import Foundation

/// On-disk layout of a `.franphotoslibrary` bundle.
///
/// ```
/// My Photos.franphotoslibrary/
/// ├── library.json                manifest (LibraryManifest)
/// ├── database/library.sqlite     authoritative metadata DB (WAL, FTS5)
/// ├── parquet/
/// │   ├── timeline/_index.parquet + YYYY/YYYY-MM.parquet
/// │   └── albums/_index.parquet + <albumUUID>.parquet
/// ├── originals/YYYY/MM/<assetUUID>.<ext>   original media (entity copies)
/// ├── derivatives/{thumbs,screen,edits}/…   rendered caches (regenerable)
/// ├── faces/<faceUUID>.jpg                  face thumbnails (flat)
/// ├── temp/
/// └── exports/
/// ```
struct LibraryPaths: Sendable {
    let root: URL

    var manifest: URL { root.appending(path: "library.json") }

    var databaseDirectory: URL { root.appending(path: "database", directoryHint: .isDirectory) }
    var database: URL { databaseDirectory.appending(path: "library.sqlite") }

    var parquetDirectory: URL { root.appending(path: "parquet", directoryHint: .isDirectory) }
    var timelineParquetDirectory: URL { parquetDirectory.appending(path: "timeline", directoryHint: .isDirectory) }
    var timelineIndexParquet: URL { timelineParquetDirectory.appending(path: "_index.parquet") }
    var albumsParquetDirectory: URL { parquetDirectory.appending(path: "albums", directoryHint: .isDirectory) }
    var albumsIndexParquet: URL { albumsParquetDirectory.appending(path: "_index.parquet") }

    var originalsDirectory: URL { root.appending(path: "originals", directoryHint: .isDirectory) }
    var derivativesDirectory: URL { root.appending(path: "derivatives", directoryHint: .isDirectory) }
    var thumbsDirectory: URL { derivativesDirectory.appending(path: "thumbs", directoryHint: .isDirectory) }
    var screenDirectory: URL { derivativesDirectory.appending(path: "screen", directoryHint: .isDirectory) }
    var editsDirectory: URL { derivativesDirectory.appending(path: "edits", directoryHint: .isDirectory) }
    var facesDirectory: URL { root.appending(path: "faces", directoryHint: .isDirectory) }
    var tempDirectory: URL { root.appending(path: "temp", directoryHint: .isDirectory) }
    var exportsDirectory: URL { root.appending(path: "exports", directoryHint: .isDirectory) }

    /// All directories that must exist in a well-formed library.
    var requiredDirectories: [URL] {
        [databaseDirectory, timelineParquetDirectory, albumsParquetDirectory,
         originalsDirectory, thumbsDirectory, screenDirectory, editsDirectory,
         facesDirectory, tempDirectory, exportsDirectory]
    }

    /// Relative path (from bundle root) for an original file, partitioned by capture date.
    /// e.g. `originals/2025/03/<uuid>.heic`
    static func originalRelativePath(uuid: UUID, capturedAt: Date, fileExtension: String) -> String {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: capturedAt)
        let month = cal.component(.month, from: capturedAt)
        let ext = fileExtension.lowercased()
        return String(format: "originals/%04d/%02d/%@.%@", year, month, uuid.uuidString, ext)
    }

    /// Timeline parquet relative path for a given month key (`YYYY-MM`).
    static func timelineParquetRelativePath(monthKey: String) -> String {
        // monthKey: "2025-03" -> parquet/timeline/2025/2025-03.parquet
        let year = String(monthKey.prefix(4))
        return "parquet/timeline/\(year)/\(monthKey).parquet"
    }

    func url(forRelativePath rel: String) -> URL {
        root.appending(path: rel)
    }
}
