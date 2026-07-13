import Foundation
import AppKit

@MainActor
final class DependencySetupViewModel: ObservableObject {
    @Published var statuses: [DependencyStatus] = DependencyService.currentStatuses()
    @Published var isInstalling = false
    @Published var installLog = ""
    @Published var isCheckingHomebrewInstall = false

    var missingRequired: [DependencyStatus] {
        DependencyService.missingRequired(in: statuses)
    }

    private var homebrewFound: Bool {
        statuses.first(where: { $0.kind == .homebrew })?.isFound ?? false
    }

    /// Missing required tools, once Homebrew itself is present — this is
    /// exactly what "Install missing tools" would pass to `brew install`.
    var installableMissingFormulas: [String] {
        guard homebrewFound else { return [] }
        var seen = Set<String>()
        var formulas: [String] = []
        for status in missingRequired {
            guard let formula = status.kind.brewFormula, !seen.contains(formula) else { continue }
            seen.insert(formula)
            formulas.append(formula)
        }
        return formulas
    }

    /// Re-resolves every dependency's path and, for anything found, its
    /// version — concurrently, since these are independent `--version`
    /// invocations. Called on first appearance and by "Check again".
    func refresh() async {
        var updated = DependencyService.currentStatuses()
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, status) in updated.enumerated() {
                guard let path = status.path else { continue }
                group.addTask {
                    (index, await DependencyService.fetchVersion(path: path))
                }
            }
            for await (index, version) in group {
                updated[index].version = version
            }
        }
        statuses = updated
    }

    /// Runs `brew install <missing formulas>` directly (no admin needed for
    /// these formulas), streaming output into `installLog` so progress is
    /// visible in the sheet itself.
    func installMissingTools() async {
        let formulas = installableMissingFormulas
        guard !formulas.isEmpty else { return }

        isInstalling = true
        installLog = ""
        let runner = ProcessRunner()
        let result = await runner.run(
            path: Tool.brew,
            arguments: ["install"] + formulas,
            qos: .userInitiated,
            onOutput: { [weak self] chunk in
                Task { @MainActor in self?.installLog += chunk }
            }
        )
        if result.exitCode != 0 {
            installLog += "\nbrew install exited with code \(result.exitCode).\n"
        }
        isInstalling = false
        await refresh()
    }

    func copyHomebrewInstallCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DependencyService.homebrewInstallCommand, forType: .string)
    }

    func openBrewWebsite() {
        guard let url = URL(string: "https://brew.sh") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Hands off to a visible Terminal window rather than running the
    /// installer hidden inside our own process — it needs admin permission
    /// and the user should see exactly what's executing, the same reason
    /// the command is also shown verbatim with a copy button above it.
    func installHomebrewInTerminal() {
        let escaped = DependencyService.homebrewInstallCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }
}
