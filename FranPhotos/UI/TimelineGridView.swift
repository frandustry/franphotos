import SwiftUI

/// The main library grid with Years / Months / Days / All Photos zoom levels,
/// backed by lazily-loaded month slices (parquet partitions).
struct TimelineGridView: View {
    @Bindable var timeline: TimelineStore
    let cache: DerivativeCache
    let db: DatabaseActor

    @State private var selection = Set<UUID>()
    @State private var cellSize: Double = 120
    @State private var previewAsset: Asset?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.4), spacing: 2)]
    }

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
            }
            ToolbarItem {
                Slider(value: $cellSize, in: 64...240)
                    .frame(width: 140)
                    .help(String(localized: "Thumbnail size"))
            }
        }
        .sheet(item: $previewAsset) { asset in
            AssetPreviewSheet(asset: asset)
        }
    }

    // MARK: - Years

    private var yearsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(timeline.years) { year in
                    SummaryCard(
                        title: String(year.year),
                        subtitle: String(localized: "\(year.assetCount) items"),
                        coverUUID: year.coverUUID, db: db, cache: cache
                    )
                    .onTapGesture { /* drill-in arrives with navigation polish */ }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Months

    private var monthsGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                ForEach(timeline.months) { month in
                    SummaryCard(
                        title: month.key.displayName,
                        subtitle: String(localized: "\(month.count) items"),
                        coverUUID: month.coverUUID, db: db, cache: cache
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Days

    private var daysGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(timeline.months) { month in
                    MonthSliceSection(timeline: timeline, monthKey: month.key,
                                      cache: cache, selection: $selection, cellSize: cellSize,
                                      groupByDay: true,
                                      onOpen: { previewAsset = $0 })
                }
            }
            .padding(2)
        }
    }

    // MARK: - All Photos

    private var allPhotosGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(timeline.months) { month in
                    MonthSliceSection(timeline: timeline, monthKey: month.key,
                                      cache: cache, selection: $selection, cellSize: cellSize,
                                      groupByDay: false,
                                      onOpen: { previewAsset = $0 })
                }
            }
            .padding(2)
        }
    }
}

/// One month section of the timeline grid. Loads its slice on first appearance —
/// this is where the parquet partition for the month is fetched (lazily).
private struct MonthSliceSection: View {
    let timeline: TimelineStore
    let monthKey: MonthKey
    let cache: DerivativeCache
    @Binding var selection: Set<UUID>
    let cellSize: Double
    let groupByDay: Bool
    var onOpen: ((Asset) -> Void)? = nil

    private var slice: MonthSlice { timeline.slice(for: monthKey) }

    var body: some View {
        Section {
            if groupByDay {
                daySubgroups
            } else {
                assetCells(slice.assets)
            }
        } header: {
            HStack {
                Text(monthKey.displayName).font(.headline)
                if slice.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .task(id: monthKey) {
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
                .gridCellColumns(gridColumnCount)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            assetCells(group.assets)
        }
    }

    private var gridColumnCount: Int {
        // Approximation for gridCellColumns spanning: wide enough to cover any row.
        12
    }

    @ViewBuilder
    private func assetCells(_ assets: [Asset]) -> some View {
        ForEach(assets) { asset in
            AssetThumbnailView(asset: asset, cache: cache)
                .overlay(selection.contains(asset.id)
                         ? Color.accentColor.opacity(0.25) : Color.clear)
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
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
