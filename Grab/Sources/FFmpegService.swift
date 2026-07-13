import Foundation

struct ColorInfo {
    let transfer: String
    let primaries: String

    /// HDR if the transfer characteristic is PQ (smpte2084) or the color
    /// primaries are BT.2020, per the spec's detection rule.
    var isHDR: Bool {
        transfer.lowercased() == "smpte2084" || primaries.lowercased().contains("bt2020")
    }

    var summary: String {
        "transfer=\(transfer), primaries=\(primaries)"
    }
}

enum FFmpegService {

    // MARK: - Color inspection

    static func probeColorInfo(fileURL: URL, runner: ProcessRunner) async -> Result<ColorInfo, GrabError> {
        let arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=color_transfer,color_primaries",
            "-of", "json",
            fileURL.path
        ]
        let result = await runner.run(path: Tool.ffprobe, arguments: arguments, qos: .userInitiated)
        guard result.exitCode == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GrabError(message: message.isEmpty ? "ffprobe exited with code \(result.exitCode)" : message))
        }
        guard let data = result.output.data(using: .utf8) else {
            return .failure(GrabError(message: "ffprobe returned unreadable output"))
        }

        struct Probe: Decodable {
            struct Stream: Decodable {
                let color_transfer: String?
                let color_primaries: String?
            }
            let streams: [Stream]
        }

        do {
            let probe = try JSONDecoder().decode(Probe.self, from: data)
            let stream = probe.streams.first
            return .success(ColorInfo(
                transfer: stream?.color_transfer ?? "unknown",
                primaries: stream?.color_primaries ?? "unknown"
            ))
        } catch {
            return .failure(GrabError(message: "Failed to parse ffprobe output: \(error.localizedDescription)"))
        }
    }

    // MARK: - ProRes conversion

    private static let hdrToneMapFilter =
        "zscale=tin=smpte2084:min=bt2020nc:pin=bt2020:rin=tv:t=smpte2084:m=bt2020nc:p=bt2020:r=tv," +
        "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0," +
        "zscale=t=bt709:m=bt709:r=tv,format=yuv422p10le"

    static func proResOutputURL(for inputURL: URL) -> URL {
        let base = inputURL.deletingPathExtension().lastPathComponent
        return inputURL.deletingLastPathComponent().appendingPathComponent("\(base)_ProRes.mov")
    }

    /// prores_videotoolbox (hardware) and prores_ks (software) both use the
    /// identical -profile:v numbering for our tier range (0=proxy...4=4444
    /// — verified via `ffmpeg -h encoder=prores_videotoolbox` and
    /// `-h encoder=prores_ks`), so no tier remapping table is needed between
    /// the two encoders.
    static let hardwareEncoder = "prores_videotoolbox"
    static let softwareEncoder = "prores_ks"

    /// Builds the ffmpeg arguments for the SDR or HDR tone-mapping path.
    /// Returns whether the HDR path was used so the caller can log it.
    /// `useHardwareEncoder` selects prores_videotoolbox vs prores_ks; the
    /// filter chain (SDR/HDR, downscale) is identical either way — only the
    /// `-c:v` encoder name differs, since the profile numbering matches.
    static func conversionArguments(
        inputURL: URL,
        outputURL: URL,
        colorInfo: ColorInfo,
        tier: ProResTier,
        downscale4K: Bool,
        useHardwareEncoder: Bool
    ) -> (arguments: [String], usedHDRPath: Bool) {
        var args: [String] = ["-y", "-i", inputURL.path]

        if colorInfo.isHDR {
            var filter = hdrToneMapFilter
            if downscale4K {
                filter += ",scale=3840:2160"
            }
            args += ["-vf", filter]
        } else if downscale4K {
            args += ["-vf", "scale=3840:2160"]
        }

        let encoder = useHardwareEncoder ? hardwareEncoder : softwareEncoder
        args += ["-c:v", encoder, "-profile:v", "\(tier.rawValue)", "-c:a", "pcm_s16le", outputURL.path]

        return (args, colorInfo.isHDR)
    }

    // MARK: - Duration + progress parsing (for the conversion progress bar)

    /// Total source duration in seconds, read-only via ffprobe. Used only to
    /// turn ffmpeg's `time=` progress lines into a percentage; does not
    /// affect the conversion arguments themselves.
    static func probeDuration(fileURL: URL, runner: ProcessRunner) async -> Result<TimeInterval, GrabError> {
        let arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            fileURL.path
        ]
        let result = await runner.run(path: Tool.ffprobe, arguments: arguments, qos: .userInitiated)
        guard result.exitCode == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GrabError(message: message.isEmpty ? "ffprobe exited with code \(result.exitCode)" : message))
        }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration = TimeInterval(trimmed), duration > 0 else {
            return .failure(GrabError(message: "ffprobe returned an unreadable duration: '\(trimmed)'"))
        }
        return .success(duration)
    }

    private static let timeRegex = try? NSRegularExpression(pattern: #"time=(\d\d):(\d\d):(\d\d(?:\.\d+)?)"#)
    private static let speedRegex = try? NSRegularExpression(pattern: #"speed=\s*([\d.]+)x"#)

    /// Parses `time=00:00:12.34` from an ffmpeg progress line into seconds.
    static func parseTimeSeconds(from text: String) -> TimeInterval? {
        guard let regex = timeRegex else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsrange),
              let hRange = Range(match.range(at: 1), in: text),
              let mRange = Range(match.range(at: 2), in: text),
              let sRange = Range(match.range(at: 3), in: text),
              let hours = Double(text[hRange]),
              let minutes = Double(text[mRange]),
              let seconds = Double(text[sRange])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Parses `speed=1.02x` from an ffmpeg progress line.
    static func parseSpeed(from text: String) -> Double? {
        guard let regex = speedRegex else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[range])
    }

    /// Formats a seconds count as "MM:SS" or "H:MM:SS" for display.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
