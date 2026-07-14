import Foundation

enum YTDLPService {

    // MARK: - Fetching metadata + formats

    /// Fetches both the video's metadata (title/thumbnail/duration/channel,
    /// shown so the user can confirm the right video was found) and its
    /// format list in a single `yt-dlp -J --no-playlist` call — one request
    /// rather than a separate `-F` table fetch plus a metadata fetch, since
    /// yt-dlp's JSON dump already contains everything the old whitespace-
    /// aligned `-F` table parser had to reconstruct by hand (and more
    /// reliably: `resolution`/`vcodec`/`format_note` come pre-separated,
    /// no column-alignment guessing needed).
    static func fetchFormats(
        url: String,
        cookiesFromBrowser: CookieBrowser,
        runner: ProcessRunner,
        onOutput: @escaping (String) -> Void
    ) async -> Result<(metadata: VideoMetadata, formats: [VideoFormat]), GrabError> {
        var arguments = ["-J", "--no-playlist", "--no-warnings"]
        if let cookieValue = cookiesFromBrowser.commandLineValue {
            arguments += ["--cookies-from-browser", cookieValue]
        }
        arguments.append(url)

        let result = await runner.run(
            path: Tool.ytdlp,
            arguments: arguments,
            qos: .userInitiated,
            onOutput: onOutput
        )
        if result.exitCode != 0 {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GrabError(message: message.isEmpty ? "yt-dlp exited with code \(result.exitCode)" : message))
        }
        guard let (metadata, formats) = parseVideoInfo(result.output) else {
            return .failure(GrabError(message: "Could not read video information for this URL."))
        }
        if formats.isEmpty {
            return .failure(GrabError(message: "No downloadable formats were found for this URL."))
        }
        return .success((metadata, formats))
    }

    /// Decodes yt-dlp's `-J` output into a `VideoMetadata` + `[VideoFormat]`
    /// pair. Parses from the first `{` to the last `}` rather than trusting
    /// the whole captured string is pure JSON — same defensive pattern as
    /// `checkForUpdate`'s brew-JSON parsing below, in case a stray line ever
    /// slips onto stdout despite `--no-warnings`.
    static func parseVideoInfo(_ output: String) -> (metadata: VideoMetadata, formats: [VideoFormat])? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else {
            return nil
        }
        guard let data = String(output[start...end]).data(using: .utf8),
              let info = try? JSONDecoder().decode(YTDLPVideoInfo.self, from: data)
        else {
            return nil
        }

        let metadata = VideoMetadata(
            title: info.title ?? "Untitled",
            thumbnailURLString: info.thumbnail,
            durationSeconds: info.duration,
            channel: info.channel ?? info.uploader
        )
        let formats = (info.formats ?? []).compactMap(videoFormat(from:))
        return (metadata, formats)
    }

    /// mhtml/storyboard entries are filtered out (checked via `ext`,
    /// `protocol`, and `format_note` — yt-dlp marks storyboards with all
    /// three, but not always consistently across extractors, so all three
    /// are checked). Audio-only rows are `vcodec == "none"`, matching
    /// yt-dlp's own JSON convention (as opposed to the old `-F` parser,
    /// which had to string-match "audio only" in the RESOLUTION column).
    private static func videoFormat(from info: YTDLPFormatInfo) -> VideoFormat? {
        let ext = info.ext ?? ""
        if ext.lowercased() == "mhtml" { return nil }
        if (info.formatProtocol ?? "").lowercased() == "mhtml" { return nil }
        if (info.formatNote ?? "").lowercased().contains("storyboard") { return nil }

        let vcodec = info.vcodec ?? "none"
        let acodec = info.acodec ?? "none"
        let isAudioOnly = vcodec.lowercased() == "none"

        let resolution: String
        if let raw = info.resolution, !raw.isEmpty {
            resolution = raw
        } else if let width = info.width, let height = info.height {
            resolution = "\(width)x\(height)"
        } else {
            resolution = isAudioOnly ? "audio only" : ""
        }

        let fps: String
        if let value = info.fps, value > 0 {
            fps = value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
        } else {
            fps = ""
        }

        return VideoFormat(
            id: info.formatID,
            ext: ext,
            resolution: resolution,
            fps: fps,
            vcodec: vcodec,
            acodec: acodec,
            filesize: formatFilesize(exact: info.filesize, approx: info.filesizeApprox),
            moreInfo: info.formatNote ?? "",
            isAudioOnly: isAudioOnly
        )
    }

    /// yt-dlp's JSON gives raw byte counts, not the human string the old
    /// `-F` table already had pre-formatted — `~` prefix (mirroring the
    /// table's own `~`/`≈` convention) when only `filesize_approx` (not the
    /// exact `filesize`) is available.
    private static func formatFilesize(exact: Int64?, approx: Int64?) -> String {
        guard let bytes = exact ?? approx else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        let formatted = formatter.string(fromByteCount: bytes)
        return exact == nil ? "~\(formatted)" : formatted
    }

    // MARK: - Downloading

    private static let outputMarker = "GRAB_OUTPUT_FILE:"

    /// Used for the automatic 403 retry (item 6) and the "Retry with
    /// Best-Quality Auto-Select" alert action: a simple adaptive selector
    /// (best video + best audio, falling back to best combined) rather than
    /// specific format IDs. Format-ID-specific requests 403 more often than
    /// this, since YouTube's changes frequently target individual streams.
    static let fallbackFormatSelector = "bv*+ba/b"

    static func downloadArguments(
        url: String,
        formatSelector: String,
        outputDir: URL,
        preferMP4: Bool,
        cookiesFromBrowser: CookieBrowser,
        sleepInterval: Bool
    ) -> [String] {
        var arguments = [
            "--no-warnings",
            "--newline",
            // yt-dlp implicitly suppresses its normal [download] progress
            // lines once --print is used (its stdout is assumed to be a
            // machine-readable pipe at that point). --progress forces the
            // progress bar back on without affecting the --print output or
            // anything about how the download/merge itself runs.
            "--progress"
        ]

        if let cookieValue = cookiesFromBrowser.commandLineValue {
            arguments += ["--cookies-from-browser", cookieValue]
        }
        if preferMP4 {
            // Prefer mp4 video / m4a audio at a given resolution, but still
            // fall back to webm rather than dropping resolution (e.g. many
            // 8K formats are webm-only) — this is exactly what yt-dlp's
            // format-sort (as opposed to a hard filter) gives you.
            arguments += ["-S", "ext:mp4:m4a"]
        }
        if sleepInterval {
            arguments += ["--sleep-interval", "5"]
        }

        let outputTemplate = outputDir.appendingPathComponent("%(title)s.%(ext)s").path
        arguments += [
            "--merge-output-format", "mp4",
            "--ffmpeg-location", Tool.ffmpegDirectory,
            "-f", formatSelector,
            "-o", outputTemplate,
            "--print", "after_move:\(outputMarker)%(filepath)s",
            url
        ]
        return arguments
    }

    /// Recovers the final downloaded file path from yt-dlp's streamed
    /// output, printed via the `after_move:` hook in `downloadArguments`.
    static func extractOutputFile(from log: String) -> String? {
        for line in log.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if let range = line.range(of: outputMarker) {
                let path = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    // MARK: - Progress parsing

    private static let progressRegex = try? NSRegularExpression(
        pattern: #"\[download\]\s+([\d.]+)%\s+of\s+.*?ETA\s+(\S+)"#
    )

    /// Parses a `--newline`-mode yt-dlp progress line such as
    /// `[download]  45.2% of   10.50MiB at    1.23MiB/s ETA 00:07`
    /// into a 0...1 fraction and the ETA string yt-dlp already computed.
    /// Pure text parsing only — does not affect the download command or
    /// its arguments in any way.
    static func parseDownloadProgress(from text: String) -> (fraction: Double, eta: String)? {
        guard let regex = progressRegex else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsrange),
              let percentRange = Range(match.range(at: 1), in: text),
              let etaRange = Range(match.range(at: 2), in: text),
              let percent = Double(text[percentRange])
        else { return nil }
        return (percent / 100.0, String(text[etaRange]))
    }

    // MARK: - Failure classification

    /// Recognized yt-dlp failure patterns that have a specific, actionable
    /// fix, as opposed to a generic/unrecognized error. String matching
    /// against well-known, stable yt-dlp error message wording.
    static func classifyFailure(_ output: String) -> YTDLPFailureKind {
        let lower = output.lowercased()

        if lower.contains("sign in to confirm") && lower.contains("bot") {
            return .botCheck
        }
        if lower.contains("confirm your age")
            || lower.contains("age-restricted")
            || lower.contains("inappropriate for some users")
            || (lower.contains("sign in") && (lower.contains("private video") || lower.contains("members-only"))) {
            return .signInRequired
        }
        if lower.contains("http error 403")
            || lower.contains("403 forbidden")
            || lower.contains("403: forbidden")
            || lower.contains("returned 403") {
            return .forbidden403
        }
        if lower.contains("video unavailable") {
            return .videoUnavailable
        }
        return .other
    }

    // MARK: - Version

    static func fetchVersion(runner: ProcessRunner) async -> String? {
        let result = await runner.run(path: Tool.ytdlp, arguments: ["--version"], qos: .utility)
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `brew outdated --json=v2 yt-dlp` prints nothing but valid JSON
    /// (`{"formulae": [], "casks": []}`) when yt-dlp is up to date, and a
    /// populated `formulae` entry when it isn't — verified directly against
    /// this machine's real Homebrew install rather than assumed from docs.
    /// Silently returns nil on any failure (brew missing, network-dependent
    /// tap refresh failing, yt-dlp not installed, unparseable output) —
    /// this is a best-effort launch check, never worth surfacing an error
    /// for. Homebrew occasionally prints a progress line ("checking for
    /// JSON API...") ahead of the JSON body depending on cache state, so
    /// parsing starts at the first `{` rather than assuming the whole
    /// captured output is pure JSON.
    static func checkForUpdate(runner: ProcessRunner) async -> YTDLPUpdateInfo? {
        guard FileManager.default.isExecutableFile(atPath: Tool.ytdlp) else { return nil }
        let result = await runner.run(path: Tool.brew, arguments: ["outdated", "--json=v2", "yt-dlp"], qos: .utility)
        guard result.exitCode == 0,
              let jsonStart = result.output.firstIndex(of: "{"),
              let data = String(result.output[jsonStart...]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(BrewOutdatedResponse.self, from: data),
              let formula = decoded.formulae.first(where: { $0.name == "yt-dlp" }),
              let installed = formula.installedVersions.last
        else { return nil }
        return YTDLPUpdateInfo(installed: installed, latest: formula.currentVersion)
    }
}

struct YTDLPUpdateInfo: Equatable {
    let installed: String
    let latest: String
}

private struct BrewOutdatedResponse: Decodable {
    let formulae: [BrewOutdatedFormula]
}

private struct BrewOutdatedFormula: Decodable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }
}

enum YTDLPFailureKind {
    case botCheck
    case signInRequired
    case forbidden403
    case videoUnavailable
    case other
}

/// Top-level shape of `yt-dlp -J`'s output — only the fields Grab actually
/// uses are declared; JSONDecoder ignores the rest.
private struct YTDLPVideoInfo: Decodable {
    let title: String?
    let thumbnail: String?
    let duration: Double?
    let uploader: String?
    let channel: String?
    let formats: [YTDLPFormatInfo]?
}

private struct YTDLPFormatInfo: Decodable {
    let formatID: String
    let ext: String?
    let resolution: String?
    let width: Int?
    let height: Int?
    let fps: Double?
    let vcodec: String?
    let acodec: String?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let formatNote: String?
    let formatProtocol: String?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case ext, resolution, width, height, fps, vcodec, acodec, filesize
        case filesizeApprox = "filesize_approx"
        case formatNote = "format_note"
        case formatProtocol = "protocol"
    }
}
