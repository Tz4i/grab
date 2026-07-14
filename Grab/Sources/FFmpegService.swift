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

    /// Reads back the container-level video codec tag (FourCC, e.g. `apcn`
    /// for ProRes 422, `apch` for 422 HQ) from a just-produced output file —
    /// used to confirm the tier->tag mapping actually holds for real
    /// (`ffmpeg -profile:v <n>` selects the encoder profile; the FourCC
    /// written into the `.mov` is a separate thing ffmpeg derives from it,
    /// so this is verifying the whole pipeline end-to-end, not just the
    /// argument we passed in).
    static func probeCodecTag(fileURL: URL, runner: ProcessRunner) async -> Result<String, GrabError> {
        let arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_tag_string",
            "-of", "default=noprint_wrappers=1:nokey=1",
            fileURL.path
        ]
        let result = await runner.run(path: Tool.ffprobe, arguments: arguments, qos: .userInitiated)
        guard result.exitCode == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GrabError(message: message.isEmpty ? "ffprobe exited with code \(result.exitCode)" : message))
        }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(GrabError(message: "ffprobe returned an empty codec tag"))
        }
        return .success(trimmed)
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

    static func h264OutputURL(for inputURL: URL) -> URL {
        let base = inputURL.deletingPathExtension().lastPathComponent
        return inputURL.deletingLastPathComponent().appendingPathComponent("\(base)_H264.mp4")
    }

    /// prores_videotoolbox (hardware) and prores_ks (software) both use the
    /// identical -profile:v numbering for our tier range (0=proxy...4=4444
    /// — verified via `ffmpeg -h encoder=prores_videotoolbox` and
    /// `-h encoder=prores_ks`), so no tier remapping table is needed between
    /// the two encoders.
    static let hardwareEncoder = "prores_videotoolbox"
    static let softwareEncoder = "prores_ks"

    static let h264HardwareEncoder = "h264_videotoolbox"
    static let h264SoftwareEncoder = "libx264"

    /// Shared between the ProRes and H.264 arg builders — the HDR
    /// detection/tone-map chain and the downscale toggle apply identically
    /// to both conversion modes. Returns nil when there's nothing to filter
    /// (SDR source, no downscale), in which case callers omit `-vf`.
    private static func videoFilter(colorInfo: ColorInfo, downscale4K: Bool) -> String? {
        if colorInfo.isHDR {
            var filter = hdrToneMapFilter
            if downscale4K {
                filter += ",scale=3840:2160"
            }
            return filter
        } else if downscale4K {
            return "scale=3840:2160"
        }
        return nil
    }

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
        if let filter = videoFilter(colorInfo: colorInfo, downscale4K: downscale4K) {
            args += ["-vf", filter]
        }

        let encoder = useHardwareEncoder ? hardwareEncoder : softwareEncoder
        args += ["-c:v", encoder, "-profile:v", "\(tier.rawValue)", "-c:a", "pcm_s16le", outputURL.path]

        return (args, colorInfo.isHDR)
    }

    /// H.264/MP4 counterpart to `conversionArguments`, same HDR/downscale
    /// filter chain. Rate control differs by encoder rather than mirroring
    /// ProRes's "identical flags either way" pattern: h264_videotoolbox
    /// exposes no CRF/quality AVOption on this ffmpeg build (verified via
    /// `ffmpeg -h encoder=h264_videotoolbox`), so the hardware path uses a
    /// flat target bitrate (`H264Quality.hardwareBitrate`) while the
    /// software path uses libx264's standard `-crf` quality control
    /// (`H264Quality.crf`).
    static func h264ConversionArguments(
        inputURL: URL,
        outputURL: URL,
        colorInfo: ColorInfo,
        quality: H264Quality,
        downscale4K: Bool,
        useHardwareEncoder: Bool
    ) -> (arguments: [String], usedHDRPath: Bool) {
        var args: [String] = ["-y", "-i", inputURL.path]
        if let filter = videoFilter(colorInfo: colorInfo, downscale4K: downscale4K) {
            args += ["-vf", filter]
        }

        args += ["-c:v", useHardwareEncoder ? h264HardwareEncoder : h264SoftwareEncoder]
        if useHardwareEncoder {
            args += ["-b:v", quality.hardwareBitrate]
        } else {
            args += ["-crf", "\(quality.crf)"]
        }
        args += ["-c:a", "aac", outputURL.path]

        return (args, colorInfo.isHDR)
    }

    // MARK: - Video dimensions (for the pre-flight disk-space estimate)

    /// Width/height/fps of the downloaded file's first video stream, used
    /// only to estimate output size before starting a conversion — not
    /// part of the conversion arguments themselves.
    static func probeVideoDimensions(
        fileURL: URL,
        runner: ProcessRunner
    ) async -> Result<(width: Int, height: Int, fps: Double), GrabError> {
        let arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate",
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
                let width: Int?
                let height: Int?
                let r_frame_rate: String?
            }
            let streams: [Stream]
        }

        do {
            let probe = try JSONDecoder().decode(Probe.self, from: data)
            guard let stream = probe.streams.first, let width = stream.width, let height = stream.height else {
                return .failure(GrabError(message: "ffprobe did not report video dimensions"))
            }
            let fps = parseFrameRateFraction(stream.r_frame_rate) ?? 30
            return .success((width, height, fps))
        } catch {
            return .failure(GrabError(message: "Failed to parse ffprobe output: \(error.localizedDescription)"))
        }
    }

    /// ffprobe reports frame rate as a fraction string like "30000/1001" or
    /// "25/1".
    private static func parseFrameRateFraction(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        guard let slashIndex = raw.firstIndex(of: "/") else { return Double(raw) }
        guard let numerator = Double(raw[raw.startIndex..<slashIndex]),
              let denominator = Double(raw[raw.index(after: slashIndex)...]),
              denominator != 0
        else { return nil }
        return numerator / denominator
    }

    // MARK: - Output size estimate (for the pre-flight disk-space check)

    /// Very rough bits-per-second estimate — good enough to catch "about to
    /// fill the disk" before spending minutes encoding, not an exact
    /// per-title prediction. ProRes rates are Apple's published reference
    /// data rates at 1920x1080/29.97fps, scaled linearly by pixel count and
    /// frame rate. H.264 reuses `H264Quality.hardwareBitrate` as the target
    /// rate regardless of hardware/software encoder — libx264's CRF mode
    /// doesn't target a fixed rate, so this is explicitly an estimate
    /// either way, and (matching hardwareBitrate itself) deliberately not
    /// resolution-scaled.
    static func estimatedBitsPerSecond(
        conversionMode: ConversionMode,
        proResTier: ProResTier,
        h264Quality: H264Quality,
        width: Int,
        height: Int,
        fps: Double
    ) -> Double {
        switch conversionMode {
        case .none:
            return 0
        case .proRes:
            let referencePixels = 1920.0 * 1080.0
            let referenceFPS = 29.97
            let pixels = Double(max(width, 1) * max(height, 1))
            let scale = (pixels / referencePixels) * (max(fps, 1) / referenceFPS)
            let baselineMbps: Double
            switch proResTier {
            case .proxy: baselineMbps = 45
            case .lt: baselineMbps = 102
            case .standard: baselineMbps = 147
            case .hq: baselineMbps = 220
            case .p4444: baselineMbps = 330
            }
            return baselineMbps * 1_000_000 * scale
        case .h264:
            let mbps: Double
            switch h264Quality {
            case .high: mbps = 12
            case .medium: mbps = 6
            case .low: mbps = 2.5
            }
            return mbps * 1_000_000
        }
    }

    static func estimateOutputBytes(
        durationSeconds: TimeInterval,
        conversionMode: ConversionMode,
        proResTier: ProResTier,
        h264Quality: H264Quality,
        width: Int,
        height: Int,
        fps: Double
    ) -> Int64 {
        let bitsPerSecond = estimatedBitsPerSecond(
            conversionMode: conversionMode, proResTier: proResTier, h264Quality: h264Quality,
            width: width, height: height, fps: fps
        )
        return Int64((bitsPerSecond / 8.0) * max(durationSeconds, 0))
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
