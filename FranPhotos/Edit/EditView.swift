import CoreImage
import SwiftUI

/// Full edit session: non-destructive recipe editing with live preview,
/// undo/redo, creative filters, geometry (rotate/straighten/crop), and
/// save-as-new-version. Originals are never modified.
struct EditView: View {
    let asset: Asset
    var onSaved: (Asset) -> Void
    var onCancel: () -> Void

    @Environment(LibraryManager.self) private var manager

    @State private var recipe: EditRecipe
    @State private var undoStack: [EditRecipe] = []
    @State private var redoStack: [EditRecipe] = []
    @State private var baseImage: CIImage?
    @State private var preview: NSImage?
    @State private var tab: EditTab = .adjust
    @State private var renderTask: Task<Void, Never>?
    @State private var isSaving = false

    enum EditTab: String, CaseIterable {
        case adjust, filters, crop
        var localizedName: String {
            switch self {
            case .adjust: String(localized: "Adjust")
            case .filters: String(localized: "Filters")
            case .crop: String(localized: "Crop")
            }
        }
    }

    init(asset: Asset, onSaved: @escaping (Asset) -> Void, onCancel: @escaping () -> Void) {
        self.asset = asset
        self.onSaved = onSaved
        self.onCancel = onCancel
        var initial = EditRecipe()
        if let json = asset.editRecipeJSON, let data = json.data(using: .utf8) {
            initial = (try? JSONDecoder().decode(EditRecipe.self, from: data)) ?? EditRecipe()
        }
        _recipe = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 0) {
            previewArea
            controlPanel
        }
        .background(Color.black.opacity(0.95))
        .task { await loadBase() }
        .onChange(of: recipe) { _, _ in schedulePreviewRender() }
    }

    // MARK: - Preview

    private var previewArea: some View {
        GeometryReader { proxy in
            ZStack {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func loadBase() async {
        let paths = manager.library?.paths
        guard let paths else { return }
        let decoded: CIImage? = await Task.detached(priority: .userInitiated) {
            // Preview base: screen-size decode of the ORIGINAL (recipe applies on top).
            let url = paths.url(forRelativePath: asset.originalRelpath)
            guard let cg = ImageDecoder.downsampledImage(at: url, maxPixelSize: 1600)
            else { return nil as CIImage? }
            return CIImage(cgImage: cg)
        }.value
        baseImage = decoded
        schedulePreviewRender()
    }

    private func schedulePreviewRender() {
        renderTask?.cancel()
        renderTask = Task { [recipe] in
            try? await Task.sleep(nanoseconds: 60_000_000)  // debounce slider drags
            guard !Task.isCancelled, let baseImage else { return }
            let rendered = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                let output = EditEngine.apply(recipe, to: baseImage)
                guard let cg = HDRCompositor.sharedContext.createCGImage(
                    output, from: output.extent, format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            guard !Task.isCancelled else { return }
            preview = rendered
        }
    }

    // MARK: - Controls

    private var controlPanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(EditTab.allCases, id: \.self) { Text($0.localizedName).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)

            ScrollView {
                switch tab {
                case .adjust: adjustPanel
                case .filters: filtersPanel
                case .crop: cropPanel
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            bottomBar
        }
        .frame(width: 280)
        .background(.windowBackground)
    }

    private var adjustPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Button(String(localized: "Auto")) {
                    guard let baseImage else { return }
                    let auto = EditEngine.autoRecipe(for: baseImage)
                    pushUndo()
                    recipe = auto
                }
                Spacer()
                Button(String(localized: "Reset")) {
                    pushUndo()
                    recipe = EditRecipe()
                }
                .disabled(recipe.isEmpty)
            }
            Group {
                slider(String(localized: "Exposure"), value: $recipe.exposure, in: -2...2)
                slider(String(localized: "Brilliance"), value: $recipe.brilliance)
                slider(String(localized: "Highlights"), value: $recipe.highlights)
                slider(String(localized: "Shadows"), value: $recipe.shadows)
                slider(String(localized: "Contrast"), value: $recipe.contrast)
                slider(String(localized: "Brightness"), value: $recipe.brightness)
                slider(String(localized: "Black Point"), value: $recipe.blackPoint)
            }
            Divider()
            Group {
                slider(String(localized: "Saturation"), value: $recipe.saturation)
                slider(String(localized: "Vibrance"), value: $recipe.vibrance)
                slider(String(localized: "Warmth"), value: $recipe.warmth)
                slider(String(localized: "Tint"), value: $recipe.tint)
            }
            Divider()
            Group {
                slider(String(localized: "Definition"), value: $recipe.definition)
                slider(String(localized: "Noise Reduction"), value: $recipe.noiseReduction, in: 0...1)
                slider(String(localized: "Sharpness"), value: $recipe.sharpness, in: 0...1)
                slider(String(localized: "Vignette"), value: $recipe.vignette)
            }
        }
        .padding(.horizontal, 14)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        in range: ClosedRange<Double> = -1...1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if editing { pushUndo() }  // snapshot at drag start
            }
        }
    }

    private var filtersPanel: some View {
        VStack(alignment: .leading) {
            filterButton(nil, label: String(localized: "Original"))
            ForEach(PhotoFilter.allCases, id: \.self) { filter in
                filterButton(filter.rawValue, label: filter.localizedName)
            }
            if recipe.filterName != nil {
                slider(String(localized: "Intensity"), value: $recipe.filterIntensity, in: 0...1)
            }
        }
        .padding(.horizontal, 14)
    }

    private func filterButton(_ name: String?, label: String) -> some View {
        Button {
            pushUndo()
            recipe.filterName = name
        } label: {
            HStack {
                Text(label)
                Spacer()
                if recipe.filterName == name {
                    Image(systemName: "checkmark")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { rotate(-1) } label: {
                    Label(String(localized: "Rotate Left"), systemImage: "rotate.left")
                }
                Button { rotate(1) } label: {
                    Label(String(localized: "Rotate Right"), systemImage: "rotate.right")
                }
                Button {
                    pushUndo()
                    recipe.flipHorizontal.toggle()
                } label: {
                    Label(String(localized: "Flip"), systemImage: "arrow.left.and.right")
                }
            }
            .labelStyle(.iconOnly)
            slider(String(localized: "Straighten"), value: $recipe.straightenDegrees, in: -45...45)
            aspectButtons
            if recipe.crop != nil {
                Button(String(localized: "Clear Crop")) {
                    pushUndo()
                    recipe.crop = nil
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private var aspectButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Crop Preset").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                presetButton("1:1", ratio: 1)
                presetButton("4:3", ratio: 4.0 / 3.0)
                presetButton("3:2", ratio: 1.5)
                presetButton("16:9", ratio: 16.0 / 9.0)
            }
        }
    }

    private func presetButton(_ label: String, ratio: Double) -> some View {
        Button(label) {
            pushUndo()
            applyAspectCrop(ratio: ratio)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func applyAspectCrop(ratio: Double) {
        // Centered crop at the given ratio, maximally filling the current frame.
        let currentRatio = 1.0  // normalized space is square-relative; compute per image
        _ = currentRatio
        guard let baseImage else { return }
        let extent = baseImage.extent
        let imageRatio = extent.width / extent.height
        var w: Double = 1.0
        var h: Double = 1.0
        if imageRatio > ratio {
            w = Double(ratio / imageRatio)  // narrower
        } else {
            h = Double(imageRatio / ratio)  // shorter
        }
        recipe.crop = EditRecipe.CropRect(
            x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func rotate(_ quarterTurns: Int) {
        pushUndo()
        recipe.rotationQuarterTurns =
            (recipe.rotationQuarterTurns + quarterTurns + 4) % 4
    }

    private var bottomBar: some View {
        HStack {
            Button { undo() } label: { Image(systemName: "arrow.uturn.left") }
                .disabled(undoStack.isEmpty)
                .help(String(localized: "Undo"))
            Button { redo() } label: { Image(systemName: "arrow.uturn.right") }
                .disabled(redoStack.isEmpty)
                .help(String(localized: "Redo"))
            Spacer()
            Button(String(localized: "Cancel"), action: onCancel)
            Button(String(localized: "Save")) { save() }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
        }
        .padding(12)
    }

    // MARK: - Undo / redo

    private func pushUndo() {
        undoStack.append(recipe)
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = previous
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
    }

    // MARK: - Save

    private func save() {
        guard let managerPaths = manager.library?.paths else { return }
        isSaving = true
        let currentRecipe = recipe
        Task {
            let newVersion = asset.editVersion + 1
            let rel = await EditEngine.renderEditDerivative(
                asset: asset, recipe: currentRecipe, version: newVersion,
                paths: managerPaths)
            guard rel != nil else {
                manager.errorMessage = String(localized: "Failed to render the edited image.")
                isSaving = false
                return
            }
            let json = (try? JSONEncoder().encode(currentRecipe))
                .flatMap { String(data: $0, encoding: .utf8) }
            if let updated = await manager.mutateAsset(asset.id, { actions in
                try await actions.setEditRecipe(asset.id, recipeJSON: json, version: newVersion)
            }) {
                await manager.derivativeCache?.invalidate(asset.id)
                isSaving = false
                onSaved(updated)
            } else {
                isSaving = false
            }
        }
    }
}
