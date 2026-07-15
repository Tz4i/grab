import SwiftUI
import Sparkle

/// Sparkle's own documented SwiftUI pattern for a "Check for Updates…"
/// menu item: `SPUUpdater.canCheckForUpdates` is a plain (non-Combine)
/// KVO-observable property, so this wraps it in a tiny ObservableObject
/// via `publisher(for:)` -- the menu item disables itself automatically
/// while a check/download is already in progress, without GrabApp or
/// AppViewModel needing to know anything about Sparkle's internal state.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// Dropped into the app menu via `.commands` in `GrabApp` (see
/// CLAUDE.md's "Auto-updates (Sparkle)" section). Calling
/// `updater.checkForUpdates()` is the *manual* check path -- distinct
/// from the automatic background check Sparkle already runs on its own
/// schedule once `SPUStandardUpdaterController` is started, but both
/// paths converge on the same standard Sparkle update UI (release notes,
/// download/install prompt) once an update is actually found.
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}
