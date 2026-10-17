import SwiftUI

@main
struct FranPhotosApp: App {
    @State private var manager = LibraryManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if manager.isLibraryOpen {
                    LibraryRootView()
                } else {
                    WelcomeView(
                        onCreate: { manager.createLibrary() },
                        onOpen: { manager.openLibrary() }
                    )
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .environment(manager)
            .alert("Error", isPresented: Binding(
                get: { manager.errorMessage != nil },
                set: { if !$0 { manager.errorMessage = nil } }
            )) {
                Button("OK") { manager.errorMessage = nil }
            } message: {
                Text(manager.errorMessage ?? "")
            }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(String(localized: "Import…")) {
                    manager.presentImportPanel()
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!manager.isLibraryOpen)
                Divider()
                Button(String(localized: "Export…")) {
                    manager.showExportSheet = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(manager.selectedAssetUUIDs.isEmpty)
            }
            CommandMenu(String(localized: "Adjust")) {
                Button(String(localized: "Adjust Date & Time / Location…")) {
                    manager.showBatchAdjustSheet = true
                }
                .disabled(manager.selectedAssetUUIDs.isEmpty)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
