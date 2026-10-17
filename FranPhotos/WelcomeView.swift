import SwiftUI

/// Placeholder root view. Will be replaced by the library browser in later steps.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Welcome to FranPhotos")
                .font(.largeTitle)
            Text("A clean, portable photo library for macOS.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    WelcomeView()
}
