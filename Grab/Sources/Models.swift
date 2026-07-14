import Foundation

struct GrabError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct VideoFormat: Identifiable, Hashable {
    let id: String
    let ext: String
    let resolution: String
    let fps: String
    let vcodec: String
    let acodec: String
    let filesize: String
    let moreInfo: String
    let isAudioOnly: Bool

    var displayCodec: String {
        let value = isAudioOnly ? acodec : vcodec
        return value.isEmpty ? "-" : value
    }

    var displayResolution: String {
        resolution.isEmpty ? "-" : resolution
    }

    var displayFPS: String {
        fps.isEmpty ? "-" : fps
    }

    var displayFilesize: String {
        filesize.isEmpty ? "-" : filesize
    }

    /// Parsed height from "WIDTHxHEIGHT", e.g. "1920x1080" -> 1080. nil for
    /// audio-only rows or anything that doesn't parse. Display-only; never
    /// used by the download/convert argument builders.
    var resolutionHeight: Int? {
        guard !isAudioOnly else { return nil }
        let parts = resolution.split(separator: "x")
        guard parts.count == 2 else { return nil }
        return Int(parts[1].trimmingCharacters(in: .whitespaces))
    }

    /// width * height, for numeric "best/highest resolution" comparisons.
    /// 0 for audio-only or unparseable rows.
    var resolutionPixels: Int {
        guard !isAudioOnly else { return 0 }
        let parts = resolution.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let height = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return 0 }
        return width * height
    }
}

/// Metadata for the video that was fetched, shown in both Basic and
/// Advanced modes so the user can confirm the right video was found before
/// downloading — see YTDLPService.fetchFormats, which now fetches this
/// alongside the format list in a single `-J` call rather than a second
/// request.
struct VideoMetadata: Equatable {
    let title: String
    let thumbnailURLString: String?
    let durationSeconds: Double?
    let channel: String?

    var thumbnailURL: URL? {
        thumbnailURLString.flatMap(URL.init(string:))
    }

    /// "H:MM:SS" once over an hour, otherwise "M:SS". "-" when yt-dlp
    /// didn't report a duration at all (e.g. live streams).
    var displayDuration: String {
        guard let durationSeconds, durationSeconds > 0 else { return "-" }
        let total = Int(durationSeconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

enum ProResTier: Int, CaseIterable, Identifiable {
    case proxy = 0
    case lt = 1
    case standard = 2
    case hq = 3
    case p4444 = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .proxy: return "Proxy"
        case .lt: return "LT"
        case .standard: return "422"
        case .hq: return "422 HQ"
        case .p4444: return "4444"
        }
    }

    /// Plain, honest, no-codec-jargon tradeoff text for Basic mode's tier
    /// picker (Advanced mode just shows `label` with no description — its
    /// users are presumed to know what a ProRes tier is).
    var basicModeTagline: String {
        switch self {
        case .proxy: return "Smallest files, lowest quality. For rough cuts."
        case .lt: return "Smaller files. Fine for simple edits."
        case .standard: return "Good balance for color correction and sharpening."
        case .hq: return "Larger files. More headroom for heavy grading."
        case .p4444: return "Largest files. Only needed for alpha/transparency."
        }
    }

    /// Basic mode's recommended default tier — 422, not 422 HQ (which
    /// Advanced mode defaults to) — see CLAUDE.md's "Basic / Advanced mode"
    /// section for why the two modes intentionally differ here.
    static let basicModeDefault: ProResTier = .standard
}

/// What happens to the file after download. `.none` keeps the downloaded
/// file as-is; `.proRes`/`.h264` both run an ffmpeg conversion pass, with
/// mode-specific settings (ProResTier / H264Quality) below.
enum ConversionMode: String, CaseIterable, Identifiable {
    case none, proRes, h264

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .proRes: return "ProRes"
        case .h264: return "H.264 (MP4)"
        }
    }

    /// Accurate tradeoff copy for the picker — deliberately does not call
    /// H.264 suitable "for After Effects"; ProRes is the edit-friendly
    /// format, H.264 trades edit performance for file size and
    /// playback-anywhere compatibility.
    var tradeoffDescription: String? {
        switch self {
        case .none:
            return nil
        case .proRes:
            return "Best for editing. Scrubs smoothly in After Effects and handles color correction well. "
                + "Large files."
        case .h264:
            return "Much smaller files. Playable anywhere. Slower to scrub and edit — fine for viewing or "
                + "light editing, less ideal for heavy compositing or grading."
        }
    }
}

/// A simple quality picker for H.264 — deliberately doesn't expose raw
/// encoder flags (CRF/bitrate) in the UI; see FFmpegService.H264Quality's
/// crf/hardwareBitrate for how each tier maps to actual encoder settings.
enum H264Quality: Int, CaseIterable, Identifiable {
    case high = 0
    case medium = 1
    case low = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// libx264 constant-quality value (lower = higher quality). Standard
    /// x264 convention: ~18 is visually near-lossless, ~23 is x264's own
    /// default/"good enough" middle ground, ~28 is noticeably compressed
    /// but still watchable.
    var crf: Int {
        switch self {
        case .high: return 18
        case .medium: return 23
        case .low: return 28
        }
    }

    /// h264_videotoolbox has no CRF/quality AVOption on this ffmpeg build
    /// (verified via `ffmpeg -h encoder=h264_videotoolbox` — only
    /// profile/level/coder/etc. are exposed, no quality or bitrate control
    /// option), so the hardware path targets a flat bitrate instead.
    /// Deliberately not resolution-scaled — kept to the spec's "simple
    /// quality picker," not adaptive to source resolution.
    var hardwareBitrate: String {
        switch self {
        case .high: return "12M"
        case .medium: return "6M"
        case .low: return "2500k"
        }
    }
}

/// Basic vs Advanced UI mode (see CLAUDE.md's "Basic / Advanced mode"
/// section). Advanced is the pre-existing full interface, unchanged;
/// Basic is a simplified "paste URL, pick a resolution, done" flow built
/// on top of the same download/convert engine. Defaults to Basic.
enum AppMode: String, CaseIterable, Identifiable {
    case basic, advanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .basic: return "Basic"
        case .advanced: return "Advanced"
        }
    }
}

/// The resolution choices offered in Basic mode's picker sheet. `.best`
/// is a sentinel ("Best available"), not a real pixel height — always
/// offered, since some video format always exists once formats have been
/// fetched. `.p720`/`.p1080`/`.p2160` are only offered when a matching
/// format actually exists for the video — see
/// BasicModeService.availableResolutionChoices.
enum BasicResolutionChoice: Int, CaseIterable, Identifiable, Equatable {
    case p720 = 720
    case p1080 = 1080
    case p2160 = 2160
    case best = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p2160: return "4K"
        case .best: return "Best available"
        }
    }
}

/// The concrete download+convert plan Basic mode hands to
/// `AppViewModel.startBasicDownload` — built by `BasicModeService.plan`
/// from a resolution choice + the "Editing quality (ProRes)" toggle. Runs
/// through the exact same `beginDownload`/`runDownloadAndConvert` engine
/// Advanced mode uses; this is purely a UI-layer simplification, not a
/// second implementation.
struct BasicDownloadPlan {
    let formatSelector: String
    let conversionMode: ConversionMode
    let h264Quality: H264Quality
    let proResTier: ProResTier
}

enum CookieBrowser: String, CaseIterable, Identifiable {
    case none, safari, chrome, firefox, brave, edge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        case .edge: return "Edge"
        }
    }

    /// yt-dlp's --cookies-from-browser accepts these lowercase names
    /// directly (verified via `yt-dlp --help`); nil means "don't pass the
    /// flag at all".
    var commandLineValue: String? {
        self == .none ? nil : rawValue
    }
}

/// Recognizes OS-level fatal failures that can surface from either
/// yt-dlp's or ffmpeg's stderr equally, since both are just processes
/// hitting the same OS write() errors on macOS. These are never worth
/// auto-retrying — retrying a disk-full failure just burns CPU/IO forever
/// without ever being able to succeed. `.none` means "not one of these
/// recognized fatal patterns" — the caller falls back to its own
/// finer-grained classification (e.g. YTDLPService.classifyFailure) for
/// transient cases like HTTP 403.
enum SystemFailureKind: Equatable {
    case diskFull
    case permissionDenied
    case missingBinary
    case invalidInput
    case none

    var isFatal: Bool { self != .none }

    static func classify(_ output: String) -> SystemFailureKind {
        let lower = output.lowercased()
        if lower.contains("no space left on device") {
            return .diskFull
        }
        if lower.contains("permission denied") {
            return .permissionDenied
        }
        if lower.contains("required tool not found") || lower.contains("failed to launch") {
            return .missingBinary
        }
        if lower.contains("invalid data found when processing input")
            || lower.contains("moov atom not found")
            || lower.contains("could not find codec parameters") {
            return .invalidInput
        }
        return .none
    }
}

/// The pre-flight "this probably won't fit" warning shown before starting
/// a conversion whose estimated output size exceeds free space on the
/// output volume. See AppViewModel.confirmEnoughDiskSpace.
struct DiskSpaceWarning: Identifiable {
    let id = UUID()
    let message: String
}

/// A failure alert with an optional one-click follow-up action, surfaced
/// when `YTDLPService.classifyFailure` recognizes a known yt-dlp failure
/// pattern in stderr (bot-check, sign-in-required, 403, unavailable).
struct ActionableAlert: Identifiable {
    enum Action {
        case openSettings
        case retryBestQuality
    }

    let id = UUID()
    let title: String
    let message: String
    let actionLabel: String
    let action: Action?

    static func make(for kind: YTDLPFailureKind) -> ActionableAlert? {
        switch kind {
        case .botCheck:
            return ActionableAlert(
                title: "YouTube Requires Verification",
                message: "YouTube is asking to confirm this isn't a bot. This is often fixed by updating yt-dlp "
                    + "(Settings → Update yt-dlp), and/or by enabling \"Use cookies from browser\" in Settings. If you have a VPN on you should turn it off.",
                actionLabel: "Open Settings",
                action: .openSettings
            )
        case .signInRequired:
            return ActionableAlert(
                title: "Sign-In Required",
                message: "This video requires you to be signed in to YouTube. Open YouTube in your browser, sign "
                    + "in, then enable \"Use cookies from browser\" in Settings and try again.",
                actionLabel: "Open Settings",
                action: .openSettings
            )
        case .forbidden403:
            return ActionableAlert(
                title: "Access Denied (403)",
                message: "YouTube refused this request. This is often fixed by updating yt-dlp (Settings → Update "
                    + "yt-dlp). You can also retry with a simpler, best-quality automatic format selection.",
                actionLabel: "Retry with Best-Quality Auto-Select",
                action: .retryBestQuality
            )
        case .videoUnavailable:
            return ActionableAlert(
                title: "Video Unavailable",
                message: "This video is unavailable — it's likely region-locked or has been removed.",
                actionLabel: "OK",
                action: nil
            )
        case .other:
            return nil
        }
    }
}
