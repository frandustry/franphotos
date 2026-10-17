import MapKit
import SwiftUI

/// Apple-Photos-style info panel: title/caption/keywords editing, complete EXIF,
/// embedded MapKit map for geotagged assets.
struct InfoPanelView: View {
    let asset: Asset
    var onMutated: (Asset) -> Void

    @Environment(LibraryManager.self) private var manager

    @State private var title: String = ""
    @State private var caption: String = ""
    @State private var keywordText: String = ""
    @State private var keywords: [String] = []
    @State private var showAdjustDate = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                Divider()
                cameraSection
                Divider()
                fileSection
                if let latitude = asset.latitude, let longitude = asset.longitude {
                    Divider()
                    mapSection(latitude: latitude, longitude: longitude)
                }
            }
            .padding(16)
        }
        .frame(width: 300)
        .background(.windowBackground)
        .task(id: asset.id) {
            title = asset.title ?? ""
            caption = asset.caption ?? ""
            keywords = (try? await manager.assetActions?.keywords(for: asset.id)) ?? []
        }
        .sheet(isPresented: $showAdjustDate) {
            AdjustDateSheet(asset: asset) { updated in
                onMutated(updated)
            }
        }
    }

    // MARK: - Header: title, caption, keywords, date

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(String(localized: "Add a Title"), text: $title)
                .textFieldStyle(.plain)
                .font(.headline)
                .onSubmit(saveTitleCaption)
            TextField(String(localized: "Add a Caption"), text: $caption, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(3...6)
                .onSubmit(saveTitleCaption)

            // Keywords as chips + add field.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 4)],
                      alignment: .leading, spacing: 4) {
                ForEach(keywords, id: \.self) { keyword in
                    HStack(spacing: 2) {
                        Text(keyword)
                        Button {
                            keywords.removeAll { $0 == keyword }
                            saveKeywords()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            TextField(String(localized: "Add Keyword (⏎)"), text: $keywordText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    let new = keywordText.trimmingCharacters(in: .whitespaces)
                    if !new.isEmpty, !keywords.contains(new) {
                        keywords.append(new)
                        saveKeywords()
                    }
                    keywordText = ""
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.capturedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.subheadline)
                Button(String(localized: "Adjust Date & Time…")) { showAdjustDate = true }
                    .font(.caption)
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: - EXIF

    @ViewBuilder
    private var cameraSection: some View {
        let rows: [(String, String)] = cameraRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline) {
                        Text(label).foregroundStyle(.secondary)
                        Spacer()
                        Text(value).multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var cameraRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let make = asset.cameraMake { rows.append((String(localized: "Make"), make)) }
        if let model = asset.cameraModel { rows.append((String(localized: "Camera"), model)) }
        if let lens = asset.lensModel { rows.append((String(localized: "Lens"), lens)) }
        if let iso = asset.iso { rows.append(("ISO", "\(iso)")) }
        if let aperture = asset.aperture {
            rows.append((String(localized: "Aperture"), String(format: "ƒ/%.1f", aperture)))
        }
        if let shutter = asset.shutterSpeed {
            let text = shutter >= 1
                ? String(format: "%.1fs", shutter)
                : "1/\(Int((1.0 / shutter).rounded()))s"
            rows.append((String(localized: "Shutter"), text))
        }
        if let focal = asset.focalLength {
            rows.append((String(localized: "Focal Length"), String(format: "%.1f mm", focal)))
        }
        if asset.hdrType != .sdr {
            rows.append(("HDR", asset.hdrType.rawValue.uppercased()))
        }
        if asset.isLivePhoto {
            rows.append(("Live Photo", String(localized: "Yes")))
        }
        if let codec = asset.videoCodec {
            rows.append((String(localized: "Codec"), codec))
        }
        if let rate = asset.frameRate {
            rows.append((String(localized: "Frame Rate"), String(format: "%.2f fps", rate)))
        }
        if let hasAudio = asset.hasAudio, asset.isVideo {
            rows.append((String(localized: "Audio"), hasAudio
                         ? String(localized: "Yes") : String(localized: "No")))
        }
        if let ms = asset.durationMs, asset.isVideo || asset.isLivePhoto {
            rows.append((String(localized: "Duration"),
                         AssetThumbnailView.formatDuration(ms: ms)))
        }
        return rows
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            infoRow(String(localized: "Filename"), asset.filename)
            infoRow(String(localized: "Dimensions"), "\(asset.width) × \(asset.height)")
            infoRow(String(localized: "Size"), ByteCountFormatter.string(
                fromByteCount: asset.fileSize, countStyle: .file))
            infoRow("UUID", asset.uuid.uuidString)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    // MARK: - Map

    private func mapSection(latitude: Double, longitude: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Location").font(.subheadline.weight(.semibold))
            Map(initialPosition: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))) {
                Marker(String(localized: "Photo Location"),
                       coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(String(format: "%.5f, %.5f", latitude, longitude))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Persistence

    private func saveTitleCaption() {
        Task {
            if let updated = await manager.mutateAsset(asset.id, { actions in
                try await actions.updateTitleCaption(uuid: asset.id,
                                                     title: title, caption: caption)
            }) {
                onMutated(updated)
            }
        }
    }

    private func saveKeywords() {
        Task {
            if let updated = await manager.mutateAsset(asset.id, { actions in
                try await actions.setKeywords(asset.id, keywords: keywords)
            }) {
                onMutated(updated)
            }
        }
    }
}

/// "Adjust Date & Time" sheet (single asset; the batch tool arrives later).
private struct AdjustDateSheet: View {
    let asset: Asset
    var onMutated: (Asset) -> Void
    @Environment(LibraryManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adjust Date & Time").font(.headline)
            DatePicker("Captured at", selection: $date)
                .datePickerStyle(.field)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Adjust")) {
                    Task {
                        if let updated = await manager.mutateAsset(asset.id, { actions in
                            try await actions.setCapturedAt(
                                asset.id, date: date,
                                tzOffsetSeconds: TimeZone.current.secondsFromGMT(for: date))
                        }) {
                            onMutated(updated)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { date = asset.capturedAt }
    }
}
