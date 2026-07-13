import Foundation

/// Every external binary Grab depends on, for the first-run/dependency
/// setup screen. `rawValue` doubles as both the executable name (matches
/// `Tool`'s resolved paths) and, where applicable, the Homebrew formula
/// name — kept as one enum rather than duplicating this list, so the
/// setup screen can't drift out of sync with what `Tool` actually checks.
enum DependencyKind: String, CaseIterable, Identifiable {
    case homebrew = "brew"
    case ytdlp = "yt-dlp"
    case ffmpeg = "ffmpeg"
    case ffprobe = "ffprobe"
    case deno = "deno"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .ytdlp: return "yt-dlp"
        case .ffmpeg: return "ffmpeg"
        case .ffprobe: return "ffprobe"
        case .deno: return "deno"
        }
    }

    var purpose: String {
        switch self {
        case .homebrew: return "Package manager needed to install the tools below."
        case .ytdlp: return "Core downloader."
        case .ffmpeg: return "Required for merging separate audio/video streams and for all conversion."
        case .ffprobe: return "Required for HDR/SDR detection. Ships with ffmpeg."
        case .deno: return "JavaScript runtime yt-dlp needs for YouTube's playback challenges. Without it, "
            + "some downloads fail confusingly."
        }
    }

    /// `brew install <formula>` target. ffprobe isn't its own formula —
    /// installing ffmpeg provides it. Homebrew itself isn't installed via
    /// `brew install` at all (see `DependencyService.homebrewInstallCommand`).
    var brewFormula: String? {
        switch self {
        case .homebrew: return nil
        case .ffprobe: return "ffmpeg"
        default: return rawValue
        }
    }

    var resolvedPath: String? {
        let path: String
        switch self {
        case .homebrew: path = Tool.brew
        case .ytdlp: path = Tool.ytdlp
        case .ffmpeg: path = Tool.ffmpeg
        case .ffprobe: path = Tool.ffprobe
        case .deno: path = Tool.deno
        }
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

struct DependencyStatus: Identifiable {
    let kind: DependencyKind
    var path: String?
    var version: String?

    var id: String { kind.id }
    var isFound: Bool { path != nil }
}

enum DependencyService {
    /// Everything the app needs to actually function. Homebrew is checked
    /// and shown on the setup screen too, but it's the installer, not
    /// something Grab itself invokes for downloads/conversion — so it's
    /// deliberately excluded here.
    static let requiredKinds: [DependencyKind] = [.ytdlp, .ffmpeg, .ffprobe, .deno]

    /// The official Homebrew install command from https://brew.sh. Shown
    /// verbatim (with a copy button) rather than run silently — installing
    /// Homebrew needs admin permission and the user should see exactly
    /// what's running.
    static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    static func currentStatuses() -> [DependencyStatus] {
        DependencyKind.allCases.map { DependencyStatus(kind: $0, path: $0.resolvedPath, version: nil) }
    }

    static func missingRequired(in statuses: [DependencyStatus]) -> [DependencyStatus] {
        statuses.filter { requiredKinds.contains($0.kind) && !$0.isFound }
    }

    /// All dependency binaries support `--version`. ffmpeg/ffprobe/deno
    /// print multi-line banners; only the first line is kept for display.
    static func fetchVersion(path: String) async -> String? {
        let result = await ProcessRunner().run(path: path, arguments: ["--version"], qos: .utility)
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.components(separatedBy: .newlines).first
    }
}
