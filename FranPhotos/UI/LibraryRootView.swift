import SwiftUI

/// Main window content once a library is open.
/// The sidebar and grid get fleshed out in later steps; for now this wires
/// import + progress reporting end to end.
struct LibraryRootView: View {
    @Environment(LibraryManager.self) private var manager
    @State private var assetCount: Int64 = 0
    @State private var isTargetedForDrop = false

    var body: some View {
        NavigationSplitView {
            List {
                Section(String(localized: "Library")) {
                    Label(String(localized: "Photos"), systemImage: "photo.stack")
                    Label(String(localized: "Videos"), systemImage: "video")
                    Label(String(localized: "Favorites"), systemImage: "heart")
                }
            }
            .navigationTitle(manager.library?.manifest.name ?? "FranPhotos")
        } detail: {
            ZStack {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("\(assetCount) items")
                        .foregroundStyle(.secondary)
                    Text("Drop photos here to import, or press ⌘I.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                if manager.isImporting {
                    importProgressOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
                handleDrop(providers)
            }
        }
        .task(id: manager.lastOutcome?.importedUUIDs) {
            await refreshCount()
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

    private func refreshCount() async {
        guard let db = manager.db else { return }
        assetCount = (try? await db.scalarInt(
            "SELECT COUNT(*) FROM assets WHERE is_deleted = 0")) ?? 0
    }
}
