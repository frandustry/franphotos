import SwiftUI

enum SidebarItem: Hashable {
    case section(LibrarySection)

    enum LibrarySection: String, CaseIterable {
        case photos, videos, livePhotos, favorites

        var localizedName: String {
            switch self {
            case .photos: String(localized: "Photos")
            case .videos: String(localized: "Videos")
            case .livePhotos: String(localized: "Live Photos")
            case .favorites: String(localized: "Favorites")
            }
        }

        var systemImage: String {
            switch self {
            case .photos: "photo.stack"
            case .videos: "video"
            case .livePhotos: "livephoto"
            case .favorites: "heart"
            }
        }
    }
}

/// Main window content once a library is open.
struct LibraryRootView: View {
    @Environment(LibraryManager.self) private var manager
    @State private var selection: SidebarItem = .section(.photos)
    @State private var isTargetedForDrop = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(String(localized: "Library")) {
                    ForEach(SidebarItem.LibrarySection.allCases, id: \.self) { section in
                        Label(section.localizedName, systemImage: section.systemImage)
                            .tag(SidebarItem.section(section))
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
        .task {
            await manager.loadTimelineIndex()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let timeline = manager.timelineStore, let cache = manager.derivativeCache,
           let db = manager.db {
            switch selection {
            case .section(.photos):
                TimelineGridView(timeline: timeline, cache: cache, db: db)
            case .section(.videos):
                FilteredAssetGridView(cache: cache, db: db,
                                      filter: .init(kind: .videos))
            case .section(.livePhotos):
                FilteredAssetGridView(cache: cache, db: db,
                                      filter: .init(kind: .livePhotos))
            case .section(.favorites):
                FilteredAssetGridView(cache: cache, db: db,
                                      filter: .init(kind: .favorites))
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
}
