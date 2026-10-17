import MapKit
import SwiftUI

/// Full-detail browser: media stage (photo/video/live photo), prev/next
/// navigation (arrows + ←/→ + space), favorite, hide, delete, info panel.
struct DetailView: View {
    let initialAsset: Asset
    let paths: LibraryPaths
    /// Navigation closures over the caller's collection (grid list or timeline).
    let nextAsset: @MainActor (Asset) async -> Asset?
    let previousAsset: @MainActor (Asset) async -> Asset?
    var onClose: () -> Void = {}

    @Environment(LibraryManager.self) private var manager
    @AppStorage("autoAdvanceAfterVideo") private var autoAdvance = true

    @State private var current: Asset
    @State private var showInfo = false
    @State private var isEditing = false
    @State private var preloadedNeighbors: [UUID: Asset] = [:]

    init(initialAsset: Asset, paths: LibraryPaths,
         nextAsset: @escaping @MainActor (Asset) async -> Asset?,
         previousAsset: @escaping @MainActor (Asset) async -> Asset?,
         onClose: @escaping () -> Void = {}) {
        self.initialAsset = initialAsset
        self.paths = paths
        self.nextAsset = nextAsset
        self.previousAsset = previousAsset
        self.onClose = onClose
        _current = State(initialValue: initialAsset)
    }

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                EditView(asset: current,
                         onSaved: { updated in
                             current = updated
                             isEditing = false
                         },
                         onCancel: { isEditing = false })
            } else {
                mainStage
            }
            if showInfo && !isEditing {
                InfoPanelView(asset: current, onMutated: { updated in
                    current = updated
                })
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showInfo)
        .background(Color.black)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { navigate(-1); return .handled }
        .onKeyPress(.rightArrow) { navigate(1); return .handled }
        .onKeyPress(.escape) {
            if isEditing { isEditing = false } else { onClose() }
            return .handled
        }
        .task(id: current.id) { preloadNeighbors() }
    }

    // MARK: - Stage

    private var mainStage: some View {
        ZStack(alignment: .top) {
            MediaStageView(
                asset: current, paths: paths,
                autoplay: false, muted: false, showsControls: true,
                onVideoFinished: { [autoAdvance] in
                    if autoAdvance { navigate(1) }
                }
            )
            .id(current.id)  // rebuild stage when navigating

            // Top toolbar
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                if current.mediaType == .photo {
                    Button { isEditing = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Edit"))
                }
                Button { toggleFavorite() } label: {
                    Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(current.isFavorite ? .red : .white)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Favorite"))
                Button { showInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help(String(localized: "Info"))
            }
            .padding(12)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [.black.opacity(0.5), .clear],
                                       startPoint: .top, endPoint: .bottom))

            // Edge navigation
            HStack {
                navButton(systemImage: "chevron.left", direction: -1)
                Spacer()
                navButton(systemImage: "chevron.right", direction: 1)
            }
            .padding(.horizontal, 8)
        }
    }

    private func navButton(systemImage: String, direction: Int) -> some View {
        Button { navigate(direction) } label: {
            Image(systemName: systemImage)
                .font(.title.weight(.semibold))
                .padding(10)
                .background(.black.opacity(0.35), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func navigate(_ direction: Int) {
        Task {
            let neighbor = direction > 0
                ? await nextAsset(current)
                : await previousAsset(current)
            guard let neighbor else { return }
            current = preloadedNeighbors[neighbor.id] ?? neighbor
        }
    }

    private func preloadNeighbors() {
        Task {
            async let next = nextAsset(current)
            async let prev = previousAsset(current)
            for candidate in [await next, await prev].compactMap({ $0 }) {
                preloadedNeighbors[candidate.id] = candidate
            }
        }
    }

    private func toggleFavorite() {
        Task {
            let newValue = !current.isFavorite
            if let updated = await manager.mutateAsset(current.id, { actions in
                try await actions.setFavorite(current.id, newValue)
            }) {
                current = updated
            }
        }
    }
}
