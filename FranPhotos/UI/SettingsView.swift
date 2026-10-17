import SwiftUI

/// App settings: language override + playback behavior.
/// Language override writes `AppleLanguages` and takes effect on next launch
/// (same approach as most macOS apps with in-app language switching).
struct SettingsView: View {
    enum Language: String, CaseIterable {
        case system, zhHans = "zh-Hans", en

        var localizedName: String {
            switch self {
            case .system: String(localized: "System Default")
            case .zhHans: "简体中文"
            case .en: "English"
            }
        }
    }

    @AppStorage("appLanguage") private var appLanguage: String = Language.system.rawValue
    @AppStorage("hoverPlaybackEnabled") private var hoverPlaybackEnabled = true
    @AppStorage("autoAdvanceAfterVideo") private var autoAdvance = true
    @AppStorage("slideshowIntervalSeconds") private var slideshowInterval: Double = 3.0

    var body: some View {
        Form {
            Section(String(localized: "General")) {
                Picker(String(localized: "Language"), selection: $appLanguage) {
                    ForEach(Language.allCases, id: \.rawValue) { lang in
                        Text(lang.localizedName).tag(lang.rawValue)
                    }
                }
                .onChange(of: appLanguage) { _, newValue in
                    applyLanguage(newValue)
                }
                Text("Language changes take effect after relaunching the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "Playback")) {
                Toggle(String(localized: "Play videos and Live Photos on hover"),
                       isOn: $hoverPlaybackEnabled)
                Toggle(String(localized: "Auto-advance after a video finishes"),
                       isOn: $autoAdvance)
                Stepper(String(localized: "Slideshow interval: \(Int(slideshowInterval))s"),
                        value: $slideshowInterval, in: 1...15, step: 1)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }

    private func applyLanguage(_ raw: String) {
        if raw == Language.system.rawValue {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([raw], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}
