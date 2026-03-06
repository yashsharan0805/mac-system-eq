import SwiftUI

@main
struct MacSystemEQApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacSystemEQ Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 760, height: 760)

        MenuBarExtra("MacSystemEQ", systemImage: "slider.horizontal.3") {
            MenuBarContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
