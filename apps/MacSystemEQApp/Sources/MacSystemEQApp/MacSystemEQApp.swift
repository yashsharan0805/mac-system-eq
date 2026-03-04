import SwiftUI

@main
struct MacSystemEQApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("MacSystemEQ", systemImage: "slider.horizontal.3") {
            MenuBarContentView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
