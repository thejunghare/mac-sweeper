import CleanerCore
import SwiftUI

@main
struct BroomApp: App {
    /// Single shared view model: owns scanning, selection and deletion state.
    @StateObject private var model = ScanViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            // ⌘R: scan again (never available mid-clean — cancel is always possible).
            CommandGroup(after: .newItem) {
                Button("Scan Again") {
                    Task { await model.startScan() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 420)
        }
    }
}
