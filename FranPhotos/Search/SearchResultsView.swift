import SwiftUI

/// Search results grid with scope filter (All / Photos / Videos / Favorites).
struct SearchResultsView: View {
    let store: SearchStore
    let cache: DerivativeCache
    let paths: LibraryPaths

    @State private var selection = Set<UUID>()
    @State private var detailAsset: Asset?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Bindable(store).scope) {
                ForEach(SearchStore.Scope.allCases, id: \.self) { scope in
                    Text(scope.localizedName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(.vertical, 8)

            if store.results.isEmpty {
                ContentUnavailableView.search
            } else {
                AssetGridView(assets: store.results, cache: cache, selection: $selection,
                              paths: paths, onOpen: { detailAsset = $0 })
            }
        }
        .overlay {
            if let detailAsset {
                DetailView(initialAsset: detailAsset, paths: paths,
                           nextAsset: { asset in
                               guard let idx = store.results.firstIndex(where: { $0.id == asset.id })
                               else { return nil }
                               return store.results[safe: idx + 1]
                           },
                           previousAsset: { asset in
                               guard let idx = store.results.firstIndex(where: { $0.id == asset.id })
                               else { return nil }
                               return store.results[safe: idx - 1]
                           },
                           onClose: { self.detailAsset = nil })
                .transition(.opacity)
            }
        }
    }
}
