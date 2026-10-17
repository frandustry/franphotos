import SwiftUI

@main
struct FranPhotosApp: App {
    var body: some Scene {
        WindowGroup {
            WelcomeView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
    }
}
