import Foundation
import Testing
@testable import FranPhotos

struct LibraryStoreTests {
    private func tempLibraryURL(_ name: String = "Test") -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "\(name).franphotoslibrary", directoryHint: .isDirectory)
    }

    @Test func createAndOpen() throws {
        let url = tempLibraryURL("Summer")
        let store = try LibraryStore.create(at: url)
        #expect(store.manifest.name == "Summer")
        #expect(store.manifest.formatVersion == LibraryManifest.currentFormatVersion)

        // All required directories exist.
        for dir in store.paths.requiredDirectories {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }

        // Reopen round-trips the manifest.
        let reopened = try LibraryStore.open(at: url)
        #expect(reopened.manifest == store.manifest)

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func createRefusesExistingPath() throws {
        let url = tempLibraryURL()
        _ = try LibraryStore.create(at: url)
        #expect(throws: LibraryError.self) {
            _ = try LibraryStore.create(at: url)
        }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func openNonLibraryThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(throws: LibraryError.self) {
            _ = try LibraryStore.open(at: dir)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func openRejectsFutureFormatVersion() throws {
        let url = tempLibraryURL()
        let store = try LibraryStore.create(at: url)
        try store.saveManifest { $0.formatVersion = LibraryManifest.currentFormatVersion + 1 }
        #expect(throws: LibraryError.self) {
            _ = try LibraryStore.open(at: url)
        }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func validateRepairsMissingDirectories() throws {
        let url = tempLibraryURL()
        let store = try LibraryStore.create(at: url)
        let fm = FileManager.default
        try fm.removeItem(at: store.paths.thumbsDirectory)
        let issues = try store.validate(repair: true)
        #expect(issues.contains { $0.severity == .repaired })
        #expect(fm.fileExists(atPath: store.paths.thumbsDirectory.path))
        try? fm.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func originalRelativePathIsDatePartitioned() {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 3; comps.day = 14
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let uuid = UUID()
        let rel = LibraryPaths.originalRelativePath(uuid: uuid, capturedAt: date, fileExtension: "HEIC")
        #expect(rel == "originals/2025/03/\(uuid.uuidString).heic")
    }
}
