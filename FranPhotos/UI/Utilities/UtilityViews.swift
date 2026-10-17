import SwiftUI

/// Hidden assets: grid + unhide action.
struct HiddenView: View {
    let cache: DerivativeCache
    let db: DatabaseActor
    let paths: LibraryPaths

    @Environment(LibraryManager.self) private var manager
    @State private var store: FilteredAssetStore?
    @State private var selection = Set<UUID>()
    @State private var detailAsset: Asset?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Hidden items don't appear in the timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Unhide Selected")) {
                    unhideSelected()
                }
                .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            grid
        }
        .task {
            let store = FilteredAssetStore(filter: .init(kind: .hidden), db: db)
            self.store = store
            await store.reload()
        }
    }

    private var grid: some View {
        Group {
            if let store {
                AssetGridView(assets: store.assets, cache: cache, selection: $selection,
                              paths: paths, onOpen: { detailAsset = $0 })
            } else {
                ProgressView()
            }
        }
        .overlay {
            if let detailAsset, let store {
                DetailView(initialAsset: detailAsset, paths: paths,
                           nextAsset: { a in store.assets[safe: (store.assets.firstIndex { $0.id == a.id } ?? -1) + 1] },
                           previousAsset: { a in store.assets[safe: (store.assets.firstIndex { $0.id == a.id } ?? 0) - 1] },
                           onClose: { self.detailAsset = nil })
            }
        }
    }

    private func unhideSelected() {
        Task {
            for uuid in selection {
                _ = await manager.mutateAsset(uuid) { actions in
                    try await actions.setHidden(uuid, false)
                }
            }
            await store?.reload()
            selection.removeAll()
        }
    }
}

/// Recently Deleted: grid + auto-purge banner + recover / permanent delete.
struct TrashView: View {
    let cache: DerivativeCache
    let db: DatabaseActor
    let paths: LibraryPaths

    @Environment(LibraryManager.self) private var manager
    @State private var store: FilteredAssetStore?
    @State private var selection = Set<UUID>()
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Items are permanently deleted after 30 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Recover Selected")) { recoverSelected() }
                    .disabled(selection.isEmpty)
                Button(String(localized: "Delete Permanently…"), role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Group {
                if let store {
                    AssetGridView(assets: store.assets, cache: cache, selection: $selection,
                                  paths: paths)
                } else {
                    ProgressView()
                }
            }
        }
        .alert(String(localized: "Delete Permanently?"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Delete"), role: .destructive) { deleteSelected() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("These items will be removed from the library immediately. This cannot be undone.")
        }
        .task {
            let store = FilteredAssetStore(filter: .init(kind: .recentlyDeleted), db: db)
            self.store = store
            await store.reload()
        }
    }

    private func recoverSelected() {
        Task {
            for uuid in selection {
                _ = await manager.mutateAsset(uuid) { actions in
                    try await actions.restoreFromTrash(uuid)
                }
            }
            await store?.reload()
            selection.removeAll()
        }
    }

    private func deleteSelected() {
        guard let paths = manager.library?.paths else { return }
        let uuids = selection
        Task {
            for uuid in uuids {
                // Remove files first, then the row.
                if let asset = try? await manager.assetActions?.fetch(uuid) {
                    let fm = FileManager.default
                    try? fm.removeItem(at: paths.url(forRelativePath: asset.originalRelpath))
                    if let live = asset.livePhotoVideoRelpath {
                        try? fm.removeItem(at: paths.url(forRelativePath: live))
                    }
                }
                _ = await manager.mutateAsset(uuid) { actions in
                    try await actions.deletePermanently(uuid)
                }
                await manager.derivativeCache?.invalidate(uuid)
            }
            await store?.reload()
            selection.removeAll()
        }
    }
}

/// Duplicates: Vision similarity scan with groups.
struct DuplicatesView: View {
    let cache: DerivativeCache
    let db: DatabaseActor
    let paths: LibraryPaths

    @Environment(LibraryManager.self) private var manager
    @State private var groups: [DuplicatesScanner.DuplicateGroup] = []
    @State private var isScanning = false
    @State private var progress: (done: Int, total: Int)?
    @State private var hasScanned = false

    var body: some View {
        VStack {
            HStack {
                Text("Visually similar photos found by on-device analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isScanning, let progress {
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                }
                Button(String(localized: hasScanned ? "Scan Again" : "Scan Now")) { scan() }
                    .disabled(isScanning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if groups.isEmpty {
                ContentUnavailableView(
                    hasScanned ? String(localized: "No Duplicates Found") : String(localized: "Find Duplicates"),
                    systemImage: "square.on.square",
                    description: Text(hasScanned
                                      ? "No visually similar photos in this library."
                                      : "Scan the library to find visually similar photos."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groups) { group in
                            DuplicateGroupRow(group: group, cache: cache, db: db, paths: paths)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func scan() {
        isScanning = true
        Task {
            let found = await DuplicatesScanner.scan(db: db, paths: paths) { done, total in
                Task { @MainActor in progress = (done, total) }
            }
            groups = found
            isScanning = false
            hasScanned = true
        }
    }
}

private struct DuplicateGroupRow: View {
    let group: DuplicatesScanner.DuplicateGroup
    let cache: DerivativeCache
    let db: DatabaseActor
    let paths: LibraryPaths
    @Environment(LibraryManager.self) private var manager
    @State private var assets: [Asset] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "\(group.assetUUIDs.count) similar items"))
                .font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(assets) { asset in
                        VStack {
                            AssetThumbnailView(asset: asset, cache: cache, paths: paths)
                                .frame(width: 120, height: 120)
                            Button(String(localized: "Move to Trash")) {
                                Task {
                                    _ = await manager.mutateAsset(asset.id) { actions in
                                        try await actions.moveToTrash(asset.id)
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .task {
            let list = group.assetUUIDs.map { "'\($0.uuidString)'" }.joined(separator: ",")
            assets = ((try? await db.query(
                "SELECT * FROM assets WHERE uuid IN (\(list))")) ?? []).map(Asset.init)
        }
    }
}
