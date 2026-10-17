import SwiftUI

/// The main library grid with Years / Months / Days / All Photos zoom levels,
/// backed by lazily-loaded month slices (parquet partitions).
struct TimelineGridView: View {
    @Bindable var timeline: TimelineStore
    let cache: DerivativeCache
    let db: DatabaseActor
    let paths: LibraryPaths

    @State private var selection = Set<UUID>()
    @State private var cellSize: Double = 120
    /// Live value while the zoom slider is being dragged; `cellSize` (which the
    /// grid actually lays out with) is only committed when the drag ends, so a
    /// drag doesn't relayout the entire lazy grid on every pixel.
    @State private var draftCellSize: Double = 120
    @State private var previewAsset: Asset?
    @State private var slideshowAssets: [Asset]?
    @Environment(LibraryManager.self) private var manager

    var body: some View {
        VStack(spacing: 0) {
            switch timeline.zoom {
            case .years: yearsGrid
            case .months: monthsGrid
            case .days: daysGrid
            case .allPhotos: allPhotosGrid
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Zoom", selection: $timeline.zoom) {
                    ForEach(TimelineStore.Zoom.allCases, id: \.self) { zoom in
                        Text(zoom.localizedName).tag(zoom)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
            ToolbarItem {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 9))
                    Slider(value: $draftCellSize, in: 64...240) { editing in
                        if !editing {
                            cellSize = draftCellSize.rounded()
                        }
                    }
                    .frame(width: 120)
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                }
                .foregroundStyle(.secondary)
                .help(String(localized: "Thumbnail size"))
            }
            ToolbarItem {
                Button { startSlideshow() } label: {
                    Image(systemName: "play.rectangle")
                }
                .help(String(localized: "Play Slideshow"))
                .disabled(selection.isEmpty)
            }
        }
        .onChange(of: selection) { _, newValue in
            manager.selectedAssetUUIDs = newValue
        }
        .overlay {
            if let previewAsset {
                DetailView(initialAsset: previewAsset, paths: paths,
                           nextAsset: { await timeline.neighbor(of: $0, direction: 1) },
                           previousAsset: { await timeline.neighbor(of: $0, direction: -1) },
                           onClose: { self.previewAsset = nil })
                .transition(.opacity)
            }
            if let slideshowAssets {
                SlideshowView(assets: slideshowAssets, paths: paths,
                              onClose: { self.slideshowAssets = nil })
                .transition(.opacity)
            }
        }
    }

    // MARK: - Years

    private var yearsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 20)], spacing: 20) {
                ForEach(timeline.years) { year in
                    SummaryCard(
                        title: String(year.year),
                        subtitle: String(localized: "\(year.assetCount) items"),
                        coverUUID: year.coverUUID, db: db, cache: cache
                    )
                    .onTapGesture { /* drill-in arrives with navigation polish */ }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Months

    private var monthsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20)], spacing: 20) {
                ForEach(timeline.months) { month in
                    SummaryCard(
                        title: month.key.displayName,
                        subtitle: String(localized: "\(month.count) items"),
                        coverUUID: month.coverUUID, db: db, cache: cache
                    )
                }
            }
            .padding(20)
        }
    }

    // MARK: - Days

    private var daysGrid: some View {
        timelineGrid(groupByDay: true)
    }

    // MARK: - All Photos

    private var allPhotosGrid: some View {
        timelineGrid(groupByDay: false)
    }

    /// Shared month-sectioned grid. The GeometryReader measures the container
    /// so GridLayout can produce exact fixed-size columns whose cells fill each
    /// row edge-to-edge with uniform square thumbnails.
    private func timelineGrid(groupByDay: Bool) -> some View {
        GeometryReader { proxy in
            let layout = GridLayout.layout(containerWidth: proxy.size.width, target: cellSize)
            ScrollView {
                LazyVGrid(columns: layout.columns, spacing: GridLayout.spacing,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(timeline.months) { month in
                        MonthSliceSection(timeline: timeline, monthKey: month.key,
                                          cache: cache, paths: paths, selection: $selection,
                                          cellSize: layout.cell, columnCount: layout.columns.count,
                                          groupByDay: groupByDay,
                                          onOpen: { previewAsset = $0 },
                                          onPlaySlideshow: startSlideshow(uuids:))
                    }
                }
                .padding(GridLayout.horizontalPadding)
            }
        }
    }

    private func startSlideshow(uuids: [UUID]) {
        Task {
            var found: [Asset] = []
            for uuid in uuids {
                if let asset = try? await manager.assetActions?.fetch(uuid) {
                    found.append(asset)
                }
            }
            if !found.isEmpty { slideshowAssets = found }
        }
    }

    private func startSlideshow() {
        startSlideshow(uuids: Array(selection))
    }
}
private struct MonthSliceSection: View {
    let timeline: TimelineStore
    let monthKey: MonthKey
    let cache: DerivativeCache
    let paths: LibraryPaths
    @Binding var selection: Set<UUID>
    let cellSize: Double
    let columnCount: Int
    let groupByDay: Bool
    var onOpen: ((Asset) -> Void)? = nil
    var onPlaySlideshow: (([UUID]) -> Void)? = nil

    private var slice: MonthSlice { timeline.slice(for: monthKey) }

    var body: some View {
        Section {
            if groupByDay {
                daySubgroups
            } else {
                assetCells(slice.assets)
            }
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(monthKey.displayName)
                    .font(.title3.bold())
                if slice.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(.bar)
        }
        // The reload token restarts loading when the slice was evicted from the
        // store's LRU pool while its section stayed on screen.
        .task(id: "\(monthKey.description)#\(slice.reloadToken)") {
            await timeline.ensureLoaded(monthKey)
        }
    }

    @ViewBuilder
    private var daySubgroups: some View {
        ForEach(slice.dayGroups, id: \.day) { group in
            Text(group.day, format: .dateTime.year().month().day())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .gridCellColumns(columnCount)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            assetCells(group.assets)
        }
    }

    @ViewBuilder
    private func assetCells(_ assets: [Asset]) -> some View {
        ForEach(assets) { asset in
            AssetThumbnailView(asset: asset, cache: cache, paths: paths, size: cellSize)
                .overlay {
                    if selection.contains(asset.id) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .draggable(dragPayload(for: asset))
                .contextMenu {
                    AssetContextMenu(assetUUIDs: selection.contains(asset.id)
                                     ? Array(selection) : [asset.id],
                                     onPlaySlideshow: onPlaySlideshow)
                }
                .onTapGesture(count: 2) {
                    selection = [asset.id]
                    onOpen?(asset)
                }
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.command) {
                        if selection.contains(asset.id) {
                            selection.remove(asset.id)
                        } else {
                            selection.insert(asset.id)
                        }
                    } else {
                        selection = [asset.id]
                    }
                }
        }
    }

    private func dragPayload(for asset: Asset) -> String {
        let uuids = selection.contains(asset.id) ? Array(selection) : [asset.id]
        return uuids.map(\.uuidString).joined(separator: ",")
    }
}

/// Card used in Years/Months zoom levels.
private struct SummaryCard: View {
    let title: String
    let subtitle: String
    let coverUUID: UUID?
    let db: DatabaseActor
    let cache: DerivativeCache

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImageView(assetUUID: coverUUID, db: db, cache: cache)
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
