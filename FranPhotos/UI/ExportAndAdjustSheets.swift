import AppKit
import SwiftUI

/// Export options sheet → destination picker → progress.
struct ExportSheet: View {
    let uuids: [UUID]
    @Environment(LibraryManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @State private var options = ExportOptions()
    @State private var isExporting = false
    @State private var progress: (done: Int, total: Int)?
    @State private var result: ExportResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Export \(uuids.count) Item(s)")).font(.headline)
            Picker(String(localized: "Format"), selection: $options.mode) {
                ForEach(ExportOptions.Mode.allCases, id: \.self) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            Toggle(String(localized: "Include Live Photo video component"),
                   isOn: $options.includeLivePhotoVideo)
            if let progress {
                ProgressView(value: Double(progress.done),
                             total: Double(max(progress.total, 1)))
            }
            if let result {
                Text(String(localized: "Exported \(result.exported) item(s)\(result.failed > 0 ? ", \(result.failed) failed" : "")"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                Button(String(localized: "Export…")) { runExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func runExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose an export destination.")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard let db = manager.db, let paths = manager.library?.paths else { return }
        isExporting = true
        Task {
            let outcome = await ExportEngine.export(
                uuids: uuids, db: db, paths: paths, destination: destination,
                options: options
            ) { done, total in
                Task { @MainActor in progress = (done, total) }
            }
            result = outcome
            isExporting = false
        }
    }
}

/// Batch adjust capture date (shift or set) and location.
struct BatchAdjustSheet: View {
    let uuids: [UUID]
    @Environment(LibraryManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    enum DateMode: String, CaseIterable {
        case shift, set
        var localizedName: String {
            switch self {
            case .shift: String(localized: "Shift by")
            case .set: String(localized: "Set to")
            }
        }
    }

    @State private var dateMode: DateMode = .shift
    @State private var shiftHours: Double = 0
    @State private var specificDate = Date()
    @State private var applyDate = true

    @State private var applyLocation = false
    @State private var latitudeText = ""
    @State private var longitudeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Adjust \(uuids.count) Item(s)")).font(.headline)

            Toggle(String(localized: "Adjust date & time"), isOn: $applyDate)
            if applyDate {
                Picker("", selection: $dateMode) {
                    ForEach(DateMode.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }
                .pickerStyle(.segmented)
                if dateMode == .shift {
                    Stepper(String(localized: "\(shiftHours, specifier: "%.1f") hours"),
                            value: $shiftHours, in: -24 * 365...24 * 365, step: 1)
                } else {
                    DatePicker(String(localized: "Captured at"), selection: $specificDate)
                }
            }

            Toggle(String(localized: "Set location"), isOn: $applyLocation)
            if applyLocation {
                HStack {
                    TextField(String(localized: "Latitude"), text: $latitudeText)
                        .textFieldStyle(.roundedBorder)
                    TextField(String(localized: "Longitude"), text: $longitudeText)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Adjust")) { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!applyDate && !applyLocation)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func apply() {
        let lat = Double(latitudeText)
        let lon = Double(longitudeText)
        Task {
            for uuid in uuids {
                _ = await manager.mutateAsset(uuid) { actions in
                    if applyDate {
                        if dateMode == .shift, shiftHours != 0 {
                            if let asset = try await actions.fetch(uuid) {
                                let shifted = asset.capturedAt.addingTimeInterval(shiftHours * 3600)
                                try await actions.setCapturedAt(
                                    uuid, date: shifted,
                                    tzOffsetSeconds: asset.capturedAtTZOffset)
                            }
                        } else if dateMode == .set {
                            try await actions.setCapturedAt(
                                uuid, date: specificDate,
                                tzOffsetSeconds: TimeZone.current.secondsFromGMT(for: specificDate))
                        }
                    }
                    if applyLocation, let lat, let lon {
                        try await actions.setLocation(uuid, latitude: lat, longitude: lon)
                    }
                }
            }
            await manager.timelineStore?.invalidate()
            dismiss()
        }
    }
}
