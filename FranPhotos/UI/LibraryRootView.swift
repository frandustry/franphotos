import SwiftUI

enum SidebarItem: Hashable {
    case section(LibrarySection)
    case utility(UtilitySection)
    case album(UUID)
    case folder(UUID)

    enum UtilitySection: String, CaseIterable {
        case hidden, recentlyDeleted, duplicates

        var localizedName: String {
            switch self {
            case .hidden: String(localized: "Hidden")
            case .recentlyDeleted: String(localized: "Recently Deleted")
            case .duplicates: String(localized: "Duplicates")
            }
        }

        var systemImage: String {
            switch self {
            case .hidden: "eye.slash"
            case .recentlyDeleted: "trash"
            case .duplicates: "square.on.square"
            }
        }
    }

    enum LibrarySection: String, CaseIterable {
        case photos, videos, livePhotos, favorites, places, memories, people

        var localizedName: String {
            switch self {
            case .photos: String(localized: "Photos")
            case .videos: String(localized: "Videos")
            case .livePhotos: String(localized: "Live Photos")
            case .favorites: String(localized: "Favorites")
            case .places: String(localized: "Places")
            case .memories: String(localized: "Memories")
            case .people: String(localized: "People")
            }
        }

        var systemImage: String {
            switch self {
            case .photos: "photo.on.rectangle.angled"
            case .videos: "video"
            case .livePhotos: "livephoto"
            case .favorites: "heart"
            case .places: "map"
            case .memories: "sparkles.rectangle.stack"
            case .people: "person.crop.rectangle.stack"
            }
        }
    }
}

/// Main window content once a library is open.
struct LibraryRootView: View {
    @Environment(LibraryManager.self) private var manager
    @State private var selection: SidebarItem = .section(.photos)
    @State private var isTargetedForDrop = false
    @State private var showNewAlbumSheet = false
    @State private var showSmartAlbumSheet = false
    @State private var newAlbumName = ""
    @State private var searchText = ""
    /// Expanded folder ids in the My Albums tree.
    @State private var expandedFolders: Set<UUID> = []
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    /// When set, the next created album/folder lands inside this folder.
    @State private var targetFolderUUID: UUID?
    @State private var renamingFolder: AlbumFolder?
    @State private var renameFolderName = ""
    @State private var folderToDelete: AlbumFolder?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(String(localized: "Library")) {
                    ForEach(SidebarItem.LibrarySection.allCases, id: \.self) { section in
                        Label(section.localizedName, systemImage: section.systemImage)
                            .tag(SidebarItem.section(section))
                    }
                }
                Section(String(localized: "Utilities")) {
                    ForEach(SidebarItem.UtilitySection.allCases, id: \.self) { section in
                        Label(section.localizedName, systemImage: section.systemImage)
                            .tag(SidebarItem.utility(section))
                    }
                }
                Section {
                    let folders = manager.albumsStore?.folders ?? []
                    let albums = manager.albumsStore?.albums ?? []
                    ForEach(folders.filter { $0.parentFolderUUID == nil }) { folder in
                        FolderSidebarRow(
                            folder: folder, depth: 0, folders: folders, albums: albums,
                            expandedFolders: $expandedFolders,
                            onNewAlbum: { targetFolderUUID = $0; newAlbumName = ""; showNewAlbumSheet = true },
                            onNewSubfolder: { targetFolderUUID = $0; newFolderName = ""; showNewFolderSheet = true },
                            onRename: { renamingFolder = $0 },
                            onDelete: { folderToDelete = $0 })
                    }
                    ForEach(albums.filter { $0.folderUUID == nil }) { album in
                        AlbumSidebarRow(album: album, depth: 0)
                    }
                } header: {
                    HStack {
                        Text("My Albums")
                        Spacer()
                        Menu {
                            Button(String(localized: "New Album")) {
                                targetFolderUUID = nil
                                showNewAlbumSheet = true
                            }
                            Button(String(localized: "New Smart Album…")) {
                                showSmartAlbumSheet = true
                            }
                            Button(String(localized: "New Folder")) {
                                targetFolderUUID = nil
                                newFolderName = ""
                                showNewFolderSheet = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 20)
                    }
                }
            }
            .navigationTitle(manager.library?.manifest.name ?? "FranPhotos")
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { if manager.isImporting { importProgressOverlay } }
                .overlay(alignment: .bottomTrailing) { exportOverlay }
                .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
                    handleDrop(providers)
                }
        }
        .searchable(text: $searchText, placement: .toolbar,
                    prompt: Text("Search photos"))
        .onChange(of: searchText) { _, text in
            manager.searchStore?.query = text
        }
        .sheet(isPresented: $showNewAlbumSheet) {
            newAlbumSheet
        }
        .sheet(isPresented: $showNewFolderSheet) {
            newFolderSheet
        }
        .sheet(item: $renamingFolder) { folder in
            renameFolderSheet(folder)
        }
        .alert(String(localized: "Delete Folder?"),
               isPresented: Binding(get: { folderToDelete != nil },
                                    set: { if !$0 { folderToDelete = nil } })) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let folder = folderToDelete {
                    Task { await manager.albumsStore?.deleteFolder(folder.uuid) }
                }
                folderToDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { folderToDelete = nil }
        } message: {
            Text(String(localized: "Albums and folders inside it will be deleted. Your photos stay in the library."))
        }
        .sheet(isPresented: $showSmartAlbumSheet) {
            SmartAlbumEditorView { name, rules in
                await manager.albumsStore?.createAlbum(name: name, rules: rules)
            }
        }
        .sheet(isPresented: Bindable(manager).showExportSheet) {
            ExportSheet(uuids: Array(manager.selectedAssetUUIDs))
        }
        .sheet(isPresented: Bindable(manager).showBatchAdjustSheet) {
            BatchAdjustSheet(uuids: Array(manager.selectedAssetUUIDs))
        }
        .task {
            await manager.loadTimelineIndex()
            await manager.albumsStore?.reload()
        }
    }

    private var newAlbumSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Album").font(.headline)
            TextField(String(localized: "Album Name"), text: $newAlbumName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    showNewAlbumSheet = false
                    newAlbumName = ""
                }
                Button(String(localized: "Create")) {
                    let name = newAlbumName.trimmingCharacters(in: .whitespaces)
                    let folder = targetFolderUUID
                    Task {
                        _ = await manager.albumsStore?.createAlbum(
                            name: name.isEmpty ? String(localized: "Untitled Album") : name,
                            in: folder)
                        newAlbumName = ""
                        targetFolderUUID = nil
                        showNewAlbumSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Folder").font(.headline)
            TextField(String(localized: "Folder Name"), text: $newFolderName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    showNewFolderSheet = false
                    newFolderName = ""
                    targetFolderUUID = nil
                }
                Button(String(localized: "Create")) {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    let parent = targetFolderUUID
                    Task {
                        _ = await manager.albumsStore?.createFolder(
                            name: name.isEmpty ? String(localized: "Untitled Folder") : name,
                            parent: parent)
                        newFolderName = ""
                        targetFolderUUID = nil
                        showNewFolderSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func renameFolderSheet(_ folder: AlbumFolder) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Folder").font(.headline)
            TextField(String(localized: "Folder Name"), text: $renameFolderName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { renamingFolder = nil }
                Button(String(localized: "Rename")) {
                    let name = renameFolderName.trimmingCharacters(in: .whitespaces)
                    Task {
                        if !name.isEmpty {
                            await manager.albumsStore?.renameFolder(folder.uuid, to: name)
                        }
                        renamingFolder = nil
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { renameFolderName = folder.name }
    }

    @ViewBuilder
    private var detailView: some View {
        if let timeline = manager.timelineStore, let cache = manager.derivativeCache,
           let db = manager.db, let paths = manager.library?.paths {
            if let search = manager.searchStore, search.isActive {
                SearchResultsView(store: search, cache: cache, paths: paths)
            } else {
                switch selection {
            case .section(.photos):
                TimelineGridView(timeline: timeline, cache: cache, db: db, paths: paths)
            case .section(.videos):
                FilteredAssetGridView(cache: cache, db: db, paths: paths,
                                      filter: .init(kind: .videos))
            case .section(.livePhotos):
                FilteredAssetGridView(cache: cache, db: db, paths: paths,
                                      filter: .init(kind: .livePhotos))
            case .section(.favorites):
                FilteredAssetGridView(cache: cache, db: db, paths: paths,
                                      filter: .init(kind: .favorites))
            case .section(.places):
                PlacesView()
            case .section(.memories):
                MemoriesView()
            case .section(.people):
                PeopleView()
            case .utility(.hidden):
                HiddenView(cache: cache, db: db, paths: paths)
            case .utility(.recentlyDeleted):
                TrashView(cache: cache, db: db, paths: paths)
            case .utility(.duplicates):
                DuplicatesView(cache: cache, db: db, paths: paths)
            case .album(let uuid):
                FilteredAssetGridView(cache: cache, db: db, paths: paths,
                                      filter: .init(kind: .album(uuid)))
            case .folder(let uuid):
                FolderContentsView(folderUUID: uuid, db: db, cache: cache,
                                   onOpenAlbum: { selection = .album($0) },
                                   onOpenFolder: { selection = .folder($0) })
                }
            }
        } else {
            ProgressView()
        }
    }

    /// Non-blocking export progress: small corner card while exporting, a
    /// dismissible summary when finished.
    @ViewBuilder
    private var exportOverlay: some View {
        if manager.isExporting {
            VStack(spacing: 8) {
                ProgressView(
                    value: Double(manager.exportProgress.done),
                    total: Double(max(1, manager.exportProgress.total)))
                Text("Exporting \(manager.exportProgress.done)/\(manager.exportProgress.total)…")
                    .font(.caption)
                Button(String(localized: "Cancel")) { manager.cancelExport() }
                    .controlSize(.small)
            }
            .padding(14)
            .frame(width: 220)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
        } else if let summary = manager.exportSummary {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(summary).font(.caption)
                Button(String(localized: "OK")) { manager.exportSummary = nil }
                    .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
    }

    private var importProgressOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: manager.importProgress.fraction) {
                Text("Importing \(manager.importProgress.currentFilename ?? "")…")
            }
            Text("\(manager.importProgress.completed)/\(manager.importProgress.total)"
                 + (manager.importProgress.duplicates > 0
                    ? " · \(manager.importProgress.duplicates) duplicates skipped" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(String(localized: "Cancel")) { manager.cancelImport() }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(40)
    }

    /// Files dropped onto the window import into the library.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            manager.importFiles(urls)
        }
        return true
    }
}
