import AppKit
import Foundation
import SwiftUI

/// Owns the currently open library and all long-lived services bound to it.
@MainActor
@Observable
final class LibraryManager {
    private(set) var library: LibraryStore?
    private(set) var db: DatabaseActor?
    private(set) var derivativeCache: DerivativeCache?

    var importProgress = ImportProgress()
    var isImporting = false
    var lastOutcome: ImportOutcome?
    var errorMessage: String?

    private var importTask: Task<Void, Never>?

    var isLibraryOpen: Bool { library != nil }

    // MARK: - Open / Create

    func createLibrary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "My Photos.\(LibraryStore.bundleExtension)"
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose where to save your new photo library.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLibraryOrReport(url, createIfMissing: true)
    }

    func openLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a FranPhotos library (.franphotoslibrary).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLibraryOrReport(url, createIfMissing: false)
    }

    func openLibraryOrReport(_ url: URL, createIfMissing: Bool) {
        Task {
            do { try await open(url, createIfMissing: createIfMissing) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func open(_ url: URL, createIfMissing: Bool) async throws {
        let store: LibraryStore
        if createIfMissing {
            store = try LibraryStore.create(at: url)
        } else {
            store = try LibraryStore.open(at: url)
        }
        try store.validate(repair: true)
        let dbActor = try await DatabaseActor.openOrCreate(at: store.paths.database)
        if !createIfMissing {
            try store.saveManifest { $0.schemaVersion = LibraryManifest.currentSchemaVersion }
        }
        self.library = store
        self.db = dbActor
        self.derivativeCache = DerivativeCache(paths: store.paths)
        self.errorMessage = nil
    }

    func closeLibrary() {
        importTask?.cancel()
        library = nil
        db = nil
        derivativeCache = nil
    }

    // MARK: - Import

    func presentImportPanel() {
        guard library != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose photos and videos to import.")
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        guard let library, let db, !urls.isEmpty else { return }
        isImporting = true
        importProgress = ImportProgress()
        importTask = Task { [weak self] in
            let engine = ImportEngine(library: library, db: db)
            let outcome = await engine.importFiles(urls) { [weak self] progress in
                self?.importProgress = progress
            }
            guard let self else { return }
            self.lastOutcome = outcome
            self.isImporting = false
        }
    }

    func cancelImport() {
        importTask?.cancel()
        isImporting = false
    }
}
