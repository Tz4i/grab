import Foundation

/// GUI apps don't inherit shell PATH, so every tool location has to be
/// resolved against known, fixed install prefixes rather than looked up via
/// `$PATH`. Homebrew installs to a different prefix depending on Mac
/// architecture, so both are checked: `/opt/homebrew` (Apple Silicon) and
/// `/usr/local` (Intel). First match wins; if neither has the binary, the
/// Apple Silicon path is reported (arbitrarily, for a single stable path in
/// error messages) and `missingTools()` will flag it.
enum Tool {
    static let searchPrefixes = ["/opt/homebrew/bin", "/usr/local/bin"]

    private static func resolve(_ name: String) -> String {
        for prefix in searchPrefixes {
            let path = "\(prefix)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "\(searchPrefixes[0])/\(name)"
    }

    static let ytdlp = resolve("yt-dlp")
    static let ffmpeg = resolve("ffmpeg")
    static let ffprobe = resolve("ffprobe")
    /// Only used by the optional "Update yt-dlp" button in Settings — not
    /// part of `missingTools()` since brew isn't required for core
    /// download/convert functionality.
    static let brew = resolve("brew")

    /// Directory containing the resolved `ffmpeg` binary, for yt-dlp's
    /// `--ffmpeg-location` flag. Falls back to the first search prefix if
    /// ffmpeg wasn't found anywhere (missingTools() will already be
    /// surfacing that as an error elsewhere).
    static var ffmpegDirectory: String {
        (ffmpeg as NSString).deletingLastPathComponent
    }

    struct Missing: Identifiable {
        let name: String
        let path: String
        var id: String { path }
    }

    static func missingTools() -> [Missing] {
        let all: [(String, String)] = [
            ("yt-dlp", ytdlp),
            ("ffmpeg", ffmpeg),
            ("ffprobe", ffprobe)
        ]
        return all
            .filter { !FileManager.default.isExecutableFile(atPath: $0.1) }
            .map { Missing(name: $0.0, path: $0.1) }
    }

    static func brewHint(for missing: [Missing]) -> String {
        let names = missing.map(\.name).joined(separator: " ")
        return "brew install \(names)"
    }
}
