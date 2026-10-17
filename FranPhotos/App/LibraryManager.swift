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
    private(set) var parquetSync: ParquetSync?
    private(set) var timelineStore: TimelineStore?
    private(set) var albumsStore: AlbumsStore?
    private(set) var searchStore: SearchStore?

    var importProgress = ImportProgress()
    var isImporting = false
    var lastOutcome: ImportOutcome?
    var errorMessage: String?

    /// Current grid selection, reported by the visible grid (drives File menu actions).
    var selectedAssetUUIDs: Set<UUID> = []
    var showExportSheet = false
    var showBatchAdjustSheet = false

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
        let sync = ParquetSync(db: dbActor, paths: store.paths)
        self.parquetSync = sync
        self.timelineStore = TimelineStore(sync: sync)
        self.albumsStore = AlbumsStore(db: dbActor, sync: sync)
        self.searchStore = SearchStore(db: dbActor)
        self.errorMessage = nil

        // Background: validate parquet partitions against SQLite and repair stale ones.
        Task { [sync] in
            try? await sync.validateAndRepair()
        }
        // Background: purge Recently Deleted items past the 30-day retention.
        Task { [dbActor, paths = store.paths] in
            _ = try? await LibraryMaintenance.purgeExpiredTrash(db: dbActor, paths: paths)
        }
    }

    func closeLibrary() {
        importTask?.cancel()
        // Best-effort: flush dirty partitions before dropping the library.
        if let sync = parquetSync {
            Task { try? await sync.syncTimeline() }
        }
        library = nil
        db = nil
        derivativeCache = nil
        parquetSync = nil
        timelineStore = nil
        albumsStore = nil
        searchStore = nil
    }

    func loadTimelineIndex() async {
        await timelineStore?.loadIndex()
    }

    var assetActions: AssetActions? {
        db.map { AssetActions(db: $0) }
    }

    /// Runs an asset mutation, marks the month dirty, syncs parquet, refreshes
    /// timeline slices, and returns the refreshed asset.
    @discardableResult
    func mutateAsset(
        _ uuid: UUID,
        _ mutation: (AssetActions) async throws -> Void
    ) async -> Asset? {
        guard let actions = assetActions else { return nil }
        do {
            try await mutation(actions)
            if let month = try await actions.monthKey(of: uuid) {
                markMonthsDirty([month])
            }
            let fresh = try await actions.fetch(uuid)
            if let fresh {
                await timelineStore?.updateAssetInSlices(fresh)
            } else {
                await timelineStore?.removeFromSlices(uuid)
            }
            return fresh
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Called after any mutation of assets: keep parquet partitions in sync.
    func markMonthsDirty(_ months: Set<MonthKey>) {
        guard let sync = parquetSync else { return }
        Task {
            try? await sync.markDirty(months: months)
            try? await sync.syncTimeline()
        }
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
            // Sync affected timeline partitions, then refresh the grid.
            if !outcome.importedUUIDs.isEmpty {
                let uuids = outcome.importedUUIDs
                Task { [weak self] in
                    guard let self, let db = self.db else { return }
                    let list = uuids.map { "'\($0.uuidString)'" }.joined(separator: ",")
                    let rows = (try? await db.query(
                        "SELECT captured_at FROM assets WHERE uuid IN (\(list))")) ?? []
                    let months = Set(rows.compactMap { $0.date("captured_at") }.map(MonthKey.init))
                    self.markMonthsDirty(months)
                    await self.timelineStore?.invalidate()
                }
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
        isImporting = false
    }
}
