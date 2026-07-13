import Foundation

enum Tool {
    static let ytdlp = "/opt/homebrew/bin/yt-dlp"
    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static let ffprobe = "/opt/homebrew/bin/ffprobe"
    /// Only used by the optional "Update yt-dlp" button in Settings — not
    /// part of `missingTools()` since brew isn't required for core
    /// download/convert functionality.
    static let brew = "/opt/homebrew/bin/brew"

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
