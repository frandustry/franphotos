import SwiftUI

/// Memories tab: grid of rule-based memory cards (On This Day, Year
/// Highlights, Trips). Tapping a card opens the detail browser over the
/// memory's assets.
struct MemoriesView: View {
    @Environment(LibraryManager.self) private var manager
    @State private var store: MemoryStore?
    @State private var openMemory: Memory?

    var body: some View {
        Group {
            if let store {
                if store.memories.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Memories"),
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("Memories appear here once your library has enough photos."))
                } else {
                    grid(store: store)
                }
            } else {
                ProgressView()
            }
        }
        .overlay {
            if let openMemory, let store, let paths = manager.library?.paths {
                let assets = store.assets(for: openMemory)
                if let first = assets.first {
                    DetailView(initialAsset: first, paths: paths,
                               nextAsset: { asset in
                                   guard let idx = assets.firstIndex(where: { $0.id == asset.id })
                                   else { return nil }
                                   return assets[safe: idx + 1]
                               },
                               previousAsset: { asset in
                                   guard let idx = assets.firstIndex(where: { $0.id == asset.id })
                                   else { return nil }
                                   return assets[safe: idx - 1]
                               },
                               onClose: { self.openMemory = nil })
                    .transition(.opacity)
                }
            }
        }
        .task {
            guard let db = manager.db else { return }
            let store = MemoryStore(db: db)
            self.store = store
            await store.loadIfNeeded()
        }
    }

    private func grid(store: MemoryStore) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(store.memories) { memory in
                    MemoryCard(memory: memory,
                               coverAsset: store.assets(for: memory).first,
                               dateRange: dateRange(for: memory, in: store),
                               cache: manager.derivativeCache)
                        .onTapGesture { openMemory = memory }
                }
            }
            .padding(16)
        }
    }

    /// "Jan 3, 2024" or "Jan 3 – Jan 7, 2024" depending on the memory's span.
    private func dateRange(for memory: Memory, in store: MemoryStore) -> String {
        let dates = store.assets(for: memory).map(\.capturedAt)
        guard let first = dates.min(), let last = dates.max() else { return "" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return first.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – "
            + last.formatted(date: .abbreviated, time: .omitted)
    }
}

/// One memory card: cover thumbnail, title, date range.
private struct MemoryCard: View {
    let memory: Memory
    let coverAsset: Asset?
    let dateRange: String
    let cache: DerivativeCache?

    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                Image(systemName: iconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(8)
            }
            Text(memory.title).font(.headline)
            Text(dateRange).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: coverAsset?.editVersion) {
            guard let cache, let coverAsset else { return }
            image = await cache.image(for: coverAsset, size: .thumb)
        }
    }

    private var iconName: String {
        switch memory.kind {
        case .onThisDay: "calendar"
        case .yearHighlight: "star"
        case .trip: "airplane"
        }
    }
}
