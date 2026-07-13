import Foundation

enum YTDLPService {

    // MARK: - Fetching formats

    static func fetchFormats(
        url: String,
        cookiesFromBrowser: CookieBrowser,
        runner: ProcessRunner,
        onOutput: @escaping (String) -> Void
    ) async -> Result<[VideoFormat], GrabError> {
        var arguments = ["-F", "--no-warnings"]
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
        let formats = parseFormats(result.output)
        if formats.isEmpty {
            return .failure(GrabError(message: "No downloadable formats were found for this URL."))
        }
        return .success(formats)
    }

    // MARK: - Defensive whitespace-aligned table parsing

    /// yt-dlp's `-F` output is a whitespace-padded table whose column widths
    /// vary per video (and can even exceed the header word's own width, e.g.
    /// a "~"/"≈"-prefixed filesize in a right-justified column). Rather than
    /// trusting header label offsets directly, we build a per-column
    /// whitespace mask across the header *and every data row*: a column
    /// index is only a separator if it is blank on every line. This finds
    /// the true field boundaries regardless of left/right justification.
    static func parseFormats(_ output: String) -> [VideoFormat] {
        let cleaned = output.replacingOccurrences(of: "|", with: " ")
        let allLines = cleaned.components(separatedBy: .newlines)

        guard let headerIndex = allLines.firstIndex(where: isHeaderLine) else { return [] }

        var tableLines: [(offset: Int, line: String)] = [(headerIndex, allLines[headerIndex])]
        for i in (headerIndex + 1)..<allLines.count {
            let line = allLines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if trimmed.allSatisfy({ $0 == "-" }) { continue }
            if trimmed.hasPrefix("[") { break }
            tableLines.append((i, line))
        }

        let headerLine = allLines[headerIndex]
        let charLines = tableLines.map { Array($0.line) }
        let maxLen = charLines.map(\.count).max() ?? 0
        guard maxLen > 0 else { return [] }

        var isGapColumn = [Bool](repeating: true, count: maxLen)
        for col in 0..<maxLen {
            for chars in charLines where col < chars.count && chars[col] != " " {
                isGapColumn[col] = false
                break
            }
        }

        var fieldRanges: [(start: Int, end: Int)] = []
        var col = 0
        while col < maxLen {
            if isGapColumn[col] { col += 1; continue }
            let start = col
            while col < maxLen, !isGapColumn[col] { col += 1 }
            fieldRanges.append((start, col))
        }
        guard !fieldRanges.isEmpty else { return [] }

        let knownLabels = [
            "ID", "EXT", "RESOLUTION", "FPS", "CH", "FILESIZE", "TBR", "PROTO",
            "VCODEC", "VBR", "ACODEC", "ABR", "ASR", "MORE INFO"
        ]
        let headerChars = Array(headerLine)
        var namedRanges: [(name: String, start: Int, end: Int)] = []
        for range in fieldRanges {
            let end = min(range.end, headerChars.count)
            guard range.start < end else { continue }
            let text = String(headerChars[range.start..<end]).trimmingCharacters(in: .whitespaces).uppercased()
            if let label = knownLabels.first(where: { $0 == text }) {
                namedRanges.append((label, range.start, range.end))
            }
        }
        guard !namedRanges.isEmpty else { return [] }

        var results: [VideoFormat] = []
        for (offset, line) in tableLines where offset != headerIndex {
            let chars = Array(line)
            var fields: [String: String] = [:]
            for range in namedRanges {
                let end = min(range.end, chars.count)
                guard range.start < end else { fields[range.name] = ""; continue }
                fields[range.name] = String(chars[range.start..<end]).trimmingCharacters(in: .whitespaces)
            }

            guard let id = fields["ID"], !id.isEmpty else { continue }
            let ext = fields["EXT"] ?? ""
            if ext.lowercased() == "mhtml" { continue }
            let moreInfo = fields["MORE INFO"] ?? ""
            if moreInfo.lowercased().contains("storyboard") { continue }
            let resolution = fields["RESOLUTION"] ?? ""
            let isAudioOnly = resolution.lowercased().contains("audio only")

            results.append(VideoFormat(
                id: id,
                ext: ext,
                resolution: resolution,
                fps: fields["FPS"] ?? "",
                vcodec: fields["VCODEC"] ?? "",
                acodec: fields["ACODEC"] ?? "",
                filesize: fields["FILESIZE"] ?? "",
                moreInfo: moreInfo,
                isAudioOnly: isAudioOnly
            ))
        }
        return results
    }

    private static func isHeaderLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper.contains("ID") && upper.contains("EXT") && upper.contains("RESOLUTION")
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
            "--ffmpeg-location", "/opt/homebrew/bin",
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
}

enum YTDLPFailureKind {
    case botCheck
    case signInRequired
    case forbidden403
    case videoUnavailable
    case other
}
