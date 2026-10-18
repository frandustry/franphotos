import MapKit
import SwiftUI

/// Places tab: all geo-tagged assets on a MapKit map with zoom-aware
/// clustering. Tapping a cluster zooms in; tapping a single asset opens a
/// popover that can present the full detail browser.
struct PlacesView: View {
    @Environment(LibraryManager.self) private var manager

    var body: some View {
        if let db = manager.db, let paths = manager.library?.paths,
           let cache = manager.derivativeCache {
            PlacesMapView(store: PlacesStore(db: db), paths: paths, cache: cache)
        } else {
            ProgressView()
        }
    }
}

private struct PlacesMapView: View {
    /// A group of assets sharing one grid cell at the current zoom level.
    struct AssetCluster: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let assets: [Asset]
    }

    let store: PlacesStore
    let paths: LibraryPaths
    let cache: DerivativeCache

    @State private var position: MapCameraPosition = .automatic
    @State private var span = MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 20)
    @State private var didFitInitialRegion = false
    @State private var popoverAsset: Asset?
    @State private var detailAsset: Asset?

    /// Buckets assets into grid cells of `span / 8` degrees; each non-empty
    /// cell becomes one cluster centered on the mean of its members.
    private var clusters: [AssetCluster] {
        let cellSize = max(span.latitudeDelta, span.longitudeDelta) / 8
        guard cellSize > 0 else { return [] }
        var groups: [String: [Asset]] = [:]
        for asset in store.assets {
            guard let lat = asset.latitude, let lon = asset.longitude else { continue }
            let key = "\(Int((lat / cellSize).rounded(.down))):\(Int((lon / cellSize).rounded(.down)))"
            groups[key, default: []].append(asset)
        }
        return groups.map { key, assets in
            let lats = assets.compactMap(\.latitude)
            let lons = assets.compactMap(\.longitude)
            let center = CLLocationCoordinate2D(
                latitude: lats.reduce(0, +) / Double(lats.count),
                longitude: lons.reduce(0, +) / Double(lons.count))
            return AssetCluster(id: key, coordinate: center, assets: assets)
        }
    }

    var body: some View {
        Map(position: $position) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.coordinate) {
                    if cluster.assets.count > 1 {
                        clusterBadge(cluster)
                    } else if let asset = cluster.assets.first {
                        singleAssetMarker(asset)
                    }
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            // Update the clustering span only on *material* zoom changes.
            // Unconditional updates closed a feedback loop: span change →
            // cluster rebuild → annotation reload → automatic camera refit →
            // camera-change callback → span change… (main thread pegged at
            // 100% CPU, effectively a hang).
            let newSpan = context.region.span
            guard newSpan.latitudeDelta.isFinite, newSpan.latitudeDelta > 0 else { return }
            let ratio = newSpan.latitudeDelta / max(span.latitudeDelta, .ulpOfOne)
            if ratio < 0.92 || ratio > 1.08 {
                span = newSpan
            }
        }
        .onChange(of: store.isLoaded) { _, loaded in
            if loaded { fitInitialRegion() }
        }
        .overlay(alignment: .bottom) {
            if store.isLoaded && store.assets.isEmpty {
                Text("No geo-tagged items in this library.")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(16)
            }
        }
        .overlay {
            if let detailAsset {
                DetailView(initialAsset: detailAsset, paths: paths,
                           nextAsset: { asset in
                               guard let idx = store.assets.firstIndex(where: { $0.id == asset.id })
                               else { return nil }
                               return store.assets[safe: idx + 1]
                           },
                           previousAsset: { asset in
                               guard let idx = store.assets.firstIndex(where: { $0.id == asset.id })
                               else { return nil }
                               return store.assets[safe: idx - 1]
                           },
                           onClose: { self.detailAsset = nil })
                .transition(.opacity)
            }
        }
        .task {
            await store.reload()
        }
    }

    /// One-time camera fit over all geo-tagged assets, then the position
    /// becomes a fixed region so annotation changes never re-frame the camera
    /// (another arm of the feedback loop described above).
    private func fitInitialRegion() {
        guard !didFitInitialRegion else { return }
        let coords: [CLLocationCoordinate2D] = store.assets.compactMap { asset in
            guard let lat = asset.latitude, let lon = asset.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard let first = coords.first else { return }
        didFitInitialRegion = true
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let fitted = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.3, 0.02),
            longitudeDelta: max((maxLon - minLon) * 1.3, 0.02))
        span = fitted
        position = .region(MKCoordinateRegion(center: center, span: fitted))
    }

    // MARK: - Annotations

    private func clusterBadge(_ cluster: AssetCluster) -> some View {
        Text("\(cluster.assets.count)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(minWidth: 28, minHeight: 28)
            .background(Color.accentColor, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
            .onTapGesture { zoom(to: cluster) }
    }

    private func singleAssetMarker(_ asset: Asset) -> some View {
        MapThumbnailView(asset: asset, cache: cache)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
            .onTapGesture { popoverAsset = asset }
            .popover(isPresented: Binding(
                get: { popoverAsset?.id == asset.id },
                set: { if !$0 { popoverAsset = nil } })
            ) {
                assetPopover(asset)
            }
    }

    // MARK: - Actions

    private func zoom(to cluster: AssetCluster) {
        let tighter = MKCoordinateSpan(
            latitudeDelta: max(span.latitudeDelta / 4, 0.005),
            longitudeDelta: max(span.longitudeDelta / 4, 0.005))
        withAnimation {
            position = .region(MKCoordinateRegion(center: cluster.coordinate, span: tighter))
        }
    }

    private func assetPopover(_ asset: Asset) -> some View {
        VStack(spacing: 10) {
            MapThumbnailView(asset: asset, cache: cache)
                .frame(width: 200, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(asset.capturedAt, format: .dateTime.year().month().day())
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(String(localized: "Open")) {
                popoverAsset = nil
                detailAsset = asset
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }
}

/// Thumbnail loaded from the derivative cache (used for map annotations and
/// the asset popover).
private struct MapThumbnailView: View {
    let asset: Asset
    let cache: DerivativeCache
    @State private var image: NSImage?

    var body: some View {
        Rectangle().fill(Color.secondary.opacity(0.15))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .task(id: asset.editVersion) {
                image = await cache.image(for: asset, size: .thumb)
            }
    }
}
