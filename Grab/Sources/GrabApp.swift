import SwiftUI

@main
struct GrabApp: App {
    var body: some Scene {
        Window("Grab", id: "main") {
            ContentView()
        }
        .windowResizability(.automatic)
        // Matches Basic mode's compact default height (see ContentView's
        // defaultWindowHeight) — Basic is the default AppMode, and
        // ContentView actively resizes the window per mode right after
        // this initial frame anyway, but starting close to the right size
        // avoids a visible grow-then-shrink flash on a fresh install.
        .defaultSize(width: 900, height: 350)

        Settings {
            SettingsView()
        }
    }
}
