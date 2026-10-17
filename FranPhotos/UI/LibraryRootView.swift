import SwiftUI

enum SidebarItem: Hashable {
    case section(LibrarySection)
    case utility(UtilitySection)
    case album(UUID)

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
            case .photos: "photo.stack"
            case .videos: "video"
            case .livePhotos: "livephoto"
            case .favorites: "heart"
            case .places: "map"
            case .memories: "sparkles.rectangle.stack"
            case .people: "person.2"
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
                    ForEach(manager.albumsStore?.albums ?? []) { album in
                        Label(album.name,
                              systemImage: album.type == .smart ? "gearshape" : "rectangle.stack")
                            .tag(SidebarItem.album(album.uuid))
                            .dropDestination(for: String.self) { payloads, _ in
                                handleAssetDrop(payloads, onto: album.uuid)
                            }
                            .contextMenu {
                                Button(String(localized: "Delete Album"), role: .destructive) {
                                    Task { await manager.albumsStore?.delete(album.uuid) }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("My Albums")
                        Spacer()
                        Menu {
                            Button(String(localized: "New Album")) { showNewAlbumSheet = true }
                            Button(String(localized: "New Smart Album…")) {
                                showSmartAlbumSheet = true
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
        .sheet(isPresented: $showSmartAlbumSheet) {
            SmartAlbumEditorView { name, rules in
                await manager.albumsStore?.createAlbum(name: name, rules: rules)
            }
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
                    Task {
                        _ = await manager.albumsStore?.createAlbum(
                            name: name.isEmpty ? String(localized: "Untitled Album") : name)
                        newAlbumName = ""
                        showNewAlbumSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
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
                }
            }
        } else {
            ProgressView()
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

    /// Grid cells drag comma-separated UUID strings; dropping onto an album adds them.
    private func handleAssetDrop(_ payloads: [String], onto albumUUID: UUID) -> Bool {
        let uuids = payloads.flatMap { $0.split(separator: ",") }
            .compactMap { UUID(uuidString: String($0)) }
        guard !uuids.isEmpty else { return false }
        Task {
            await manager.albumsStore?.add(uuids, to: albumUUID)
        }
        return true
    }
}
