import SwiftUI

@main
struct GrabApp: App {
    var body: some Scene {
        Window("Grab", id: "main") {
            ContentView()
        }
        .windowResizability(.automatic)
        .defaultSize(width: 900, height: 780)

        Settings {
            SettingsView()
        }
    }
}
