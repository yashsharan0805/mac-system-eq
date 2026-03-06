import SwiftUI

@main
struct MacSystemEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }
    }
}
