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
    /// Prefetched neighbors: navigation uses them synchronously so paging is
    /// instant, and their screen-size derivatives are warmed in the cache.
    @State private var preloadedNext: Asset?
    @State private var preloadedPrev: Asset?

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
        .task(id: current.id) { preloadNeighbors(of: current) }
    }

    // MARK: - Stage

    private var mainStage: some View {
        ZStack(alignment: .top) {
            MediaStageView(
                asset: current, paths: paths,
                autoplay: false, muted: false, showsControls: true,
                badgeTopInset: 60,  // clears the floating toolbar
                onVideoFinished: { [autoAdvance] in
                    if autoAdvance { navigate(1) }
                }
            )
            .id(current.id)  // rebuild stage when navigating
            .transition(.opacity)

            // Edge navigation — vertically centered, below the toolbar layer.
            HStack {
                navButton(systemImage: "chevron.left", direction: -1)
                Spacer()
                navButton(systemImage: "chevron.right", direction: 1)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 10)

            // Top toolbar (last layer: always on top, always clickable).
            HStack(spacing: 10) {
                toolbarButton(systemName: "chevron.backward",
                              help: String(localized: "Back"),
                              action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if current.mediaType == .photo {
                    toolbarButton(systemName: "slider.horizontal.3",
                                  help: String(localized: "Edit")) {
                        isEditing = true
                    }
                }
                toolbarButton(
                    systemName: current.isFavorite ? "heart.fill" : "heart",
                    help: String(localized: "Favorite"),
                    tint: current.isFavorite ? .red : nil
                ) { toggleFavorite() }
                toolbarButton(systemName: "info.circle",
                              help: String(localized: "Info")) {
                    showInfo.toggle()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false))
        }
    }

    private func toolbarButton(systemName: String, help: String,
                               tint: Color? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? .white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func navButton(systemImage: String, direction: Int) -> some View {
        Button { navigate(direction) } label: {
            Image(systemName: systemImage)
                .font(.title.weight(.semibold))
                .padding(10)
                .background(.black.opacity(0.35), in: Circle())
                .foregroundStyle(.white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(0.85)
    }

    // MARK: - Actions

    /// Instant when the target neighbor was prefetched (the common case);
    /// otherwise falls back to an async lookup.
    private func navigate(_ direction: Int) {
        let preloaded = direction > 0 ? preloadedNext : preloadedPrev
        if let preloaded {
            preloadedNext = nil
            preloadedPrev = nil
            withAnimation(.easeInOut(duration: 0.15)) {
                current = preloaded
            }
            return
        }
        Task {
            let neighbor = direction > 0
                ? await nextAsset(current)
                : await previousAsset(current)
            guard let neighbor else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                current = neighbor
            }
        }
    }

    /// Prefetches both neighbor assets AND warms their screen-size derivatives,
    /// so paging renders immediately instead of flashing a black placeholder.
    private func preloadNeighbors(of origin: Asset) {
        Task {
            async let next = nextAsset(origin)
            async let prev = previousAsset(origin)
            let (n, p) = await (next, prev)
            // Discard if the user already navigated elsewhere meanwhile.
            guard current.id == origin.id else { return }
            preloadedNext = n
            preloadedPrev = p
            if let cache = manager.derivativeCache {
                for candidate in [n, p].compactMap({ $0 }) {
                    _ = await cache.image(for: candidate, size: .screen)
                }
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
