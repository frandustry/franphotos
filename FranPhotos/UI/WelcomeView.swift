import SwiftUI

/// Shown when no library is open.
struct WelcomeView: View {
    let onCreate: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Welcome to FranPhotos")
                .font(.largeTitle)
            Text("A clean, portable photo library for macOS.")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button(String(localized: "Create Library…"), action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button(String(localized: "Open Library…"), action: onOpen)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
