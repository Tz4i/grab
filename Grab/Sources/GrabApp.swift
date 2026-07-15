import SwiftUI
import Sparkle

@main
struct GrabApp: App {
    /// `startingUpdater: true` starts Sparkle's own background update
    /// scheduler immediately (non-blocking -- it's a plain background
    /// URLSession fetch against SUFeedURL, on the interval Sparkle
    /// manages itself per SUEnableAutomaticChecks/SUScheduledCheckInterval
    /// in Info.plist). Kept as a `private let` on the App struct itself
    /// (not inside ContentView/AppViewModel) since it must live for the
    /// whole app lifetime and has nothing to do with the download/convert
    /// pipeline -- see CLAUDE.md's "Auto-updates (Sparkle)" section.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
