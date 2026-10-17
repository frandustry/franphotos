import Foundation

enum LibraryError: LocalizedError {
    case bundleAlreadyExists(URL)
    case notALibrary(URL)
    case manifestUnreadable(String)
    case unsupportedFormatVersion(found: Int, supported: Int)
    case databaseMissing(URL)

    var errorDescription: String? {
        switch self {
        case .bundleAlreadyExists(let url):
            "A file already exists at \(url.path)."
        case .notALibrary(let url):
            "\(url.lastPathComponent) is not a FranPhotos library."
        case .manifestUnreadable(let detail):
            "The library manifest could not be read: \(detail)"
        case .unsupportedFormatVersion(let found, let supported):
            "This library uses format version \(found), but this app supports up to version \(supported)."
        case .databaseMissing(let url):
            "The library database is missing at \(url.path)."
        }
    }
}

struct LibraryIssue: Sendable, Equatable {
    enum Severity: Sendable { case repaired, warning, fatal }
    let severity: Severity
    let message: String
}

/// Owns an opened `.franphotoslibrary` bundle: manifest, paths, validation and repair.
/// Database and media access layers are built on top of this (see DatabaseActor, ImportEngine).
final class LibraryStore: @unchecked Sendable {
    static let bundleExtension = "franphotoslibrary"

    let paths: LibraryPaths
    private(set) var manifest: LibraryManifest

    private init(root: URL, manifest: LibraryManifest) {
        self.paths = LibraryPaths(root: root)
        self.manifest = manifest
    }

    // MARK: - Create

    /// Creates a new library bundle at `url` (which should end in `.franphotoslibrary`).
    /// The URL must not exist yet — we never silently overwrite user data.
    @discardableResult
    static func create(at url: URL, name: String? = nil, appVersion: String = "0.1.0") throws -> LibraryStore {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            throw LibraryError.bundleAlreadyExists(url)
        }
        let paths = LibraryPaths(root: url)
        for dir in paths.requiredDirectories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let manifest = LibraryManifest.fresh(
            name: name ?? url.deletingPathExtension().lastPathComponent,
            appVersion: appVersion
        )
        let data = try LibraryManifest.jsonEncoder.encode(manifest)
        try data.write(to: paths.manifest, options: .atomic)
        return LibraryStore(root: url, manifest: manifest)
    }

    // MARK: - Open

    /// Opens an existing library. Throws if the bundle is not a FranPhotos library or
    /// was created by a newer, incompatible version of the app.
    static func open(at url: URL) throws -> LibraryStore {
        let paths = LibraryPaths(root: url)
        guard FileManager.default.fileExists(atPath: paths.manifest.path) else {
            throw LibraryError.notALibrary(url)
        }
        let manifest: LibraryManifest
        do {
            let data = try Data(contentsOf: paths.manifest)
            manifest = try LibraryManifest.jsonDecoder.decode(LibraryManifest.self, from: data)
        } catch {
            throw LibraryError.manifestUnreadable(error.localizedDescription)
        }
        guard manifest.formatVersion <= LibraryManifest.currentFormatVersion else {
            throw LibraryError.unsupportedFormatVersion(
                found: manifest.formatVersion,
                supported: LibraryManifest.currentFormatVersion
            )
        }
        return LibraryStore(root: url, manifest: manifest)
    }

    /// Opens an existing library, or creates one if nothing exists at the URL.
    static func openOrCreate(at url: URL, appVersion: String = "0.1.0") throws -> LibraryStore {
        if FileManager.default.fileExists(atPath: url.path) {
            try open(at: url)
        } else {
            try create(at: url, appVersion: appVersion)
        }
    }

    // MARK: - Validation & repair

    /// Checks the bundle structure. Missing *regenerable* directories are recreated
    /// (reported as `.repaired`). Missing database is fatal at this layer — the caller
    /// decides whether to initialize a fresh schema (new library) or surface an error.
    @discardableResult
    func validate(repair: Bool = true) throws -> [LibraryIssue] {
        var issues: [LibraryIssue] = []
        let fm = FileManager.default
        for dir in paths.requiredDirectories {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
                if repair {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    issues.append(LibraryIssue(
                        severity: .repaired,
                        message: "Recreated missing directory \(dir.lastPathComponent)"))
                } else {
                    issues.append(LibraryIssue(
                        severity: .fatal,
                        message: "Missing directory \(dir.lastPathComponent)"))
                }
            }
        }
        return issues
    }

    var hasDatabase: Bool {
        FileManager.default.fileExists(atPath: paths.database.path)
    }

    /// Rewrites `library.json` (e.g. after a schema migration bumps schemaVersion).
    func saveManifest(_ update: (inout LibraryManifest) -> Void) throws {
        var m = manifest
        update(&m)
        let data = try LibraryManifest.jsonEncoder.encode(m)
        try data.write(to: paths.manifest, options: .atomic)
        manifest = m
    }
}
