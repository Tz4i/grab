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

enum ProResTier: Int, CaseIterable, Identifiable, Codable {
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
enum ConversionMode: String, CaseIterable, Identifiable, Codable {
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
enum H264Quality: Int, CaseIterable, Identifiable, Codable {
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

enum CookieBrowser: String, CaseIterable, Identifiable, Codable {
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

// MARK: - Playlists

/// One entry from a `yt-dlp --flat-playlist -J` enumeration — deliberately
/// lightweight (id/title/duration only, no format list) since flat mode
/// doesn't fetch per-video formats; see YTDLPService.fetchPlaylistEntries.
/// `url` is always reconstructed as a canonical `watch?v=<id>` link rather
/// than trusted verbatim from yt-dlp's own JSON (defensive — verified this
/// yt-dlp version's flat-playlist entries already carry the same canonical
/// form in their own `url` field, but that's not a stable contract across
/// versions/extractors worth depending on).
struct PlaylistEntry: Identifiable, Equatable {
    let id: String
    let url: String
    let title: String
    let durationSeconds: Double?

    /// Same M:SS / H:MM:SS / "-" formatting as `VideoMetadata.displayDuration`.
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

/// The video-quality ceiling automatically applied to every job in a
/// playlist queue — picking a format per-video doesn't scale for a
/// 20-item playlist, so this replaces that with one policy for the whole
/// batch. `.bestAvailable` is uncapped; the other two cap the candidate
/// pool by height before picking the best match within it (see
/// BasicModeService.planForPolicy / PlaylistFormatSelector.
/// advancedFormatSelector) — a ceiling, not a hard requirement, so a
/// video that doesn't have anything at or below the cap still gets its
/// actual best available format rather than failing the job outright.
enum PlaylistFormatPolicy: String, CaseIterable, Identifiable, Codable {
    case bestAvailable, bestUpTo4K, bestUpTo1080p

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bestAvailable: return "Best available"
        case .bestUpTo4K: return "Best up to 4K"
        case .bestUpTo1080p: return "Best up to 1080p"
        }
    }

    /// nil means uncapped.
    var heightCap: Int? {
        switch self {
        case .bestAvailable: return nil
        case .bestUpTo4K: return 2160
        case .bestUpTo1080p: return 1080
        }
    }
}

/// Settings default for the "this link has both a video and a playlist"
/// disambiguation prompt — see YouTubeURLKind.classify and ContentView's
/// URL-submit gate. Defaults to `.alwaysAsk`.
enum PlaylistPromptDefault: String, CaseIterable, Identifiable {
    case alwaysAsk, justVideo, alwaysPlaylist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alwaysAsk: return "Always ask"
        case .justVideo: return "Just the video"
        case .alwaysPlaylist: return "Always the playlist"
        }
    }
}

/// What a pasted URL actually refers to, for the purposes of deciding
/// whether to show the video-vs-playlist disambiguation prompt. Pure
/// string/URLComponents parsing, no network — a video id is recognized
/// via a `v` query param or a `youtu.be`/`/shorts/`/`/embed/`/`/live/`
/// path segment; a playlist is recognized via a nonempty `list` query
/// param; the two are checked independently, then combined. Anything
/// that doesn't parse as a URL, or isn't recognized as a YouTube link at
/// all, is `.other` — callers must treat that identically to
/// `.singleVideo` (fall through to the existing, unchanged single-video
/// path), so an arbitrary/non-YouTube URL never gets stuck behind a
/// playlist prompt it can never satisfy.
enum YouTubeURLKind: Equatable {
    case singleVideo
    case videoWithPlaylist
    case playlistOnly
    case other

    static func classify(_ urlString: String) -> YouTubeURLKind {
        guard let components = URLComponents(string: urlString), let host = components.host?.lowercased() else {
            return .other
        }
        guard host.contains("youtube.com") || host.contains("youtu.be") else {
            return .other
        }

        let queryItems = components.queryItems ?? []
        let hasListParam = queryItems.contains { $0.name == "list" && !($0.value ?? "").isEmpty }

        let pathComponents = components.path.split(separator: "/").map(String.init)
        let hasVideoIDFromPath = host.contains("youtu.be")
            ? !pathComponents.isEmpty
            : ["shorts", "embed", "live"].contains(pathComponents.first ?? "") && pathComponents.count > 1
        let hasVideoIDFromQuery = queryItems.contains { $0.name == "v" && !($0.value ?? "").isEmpty }
        let hasVideoID = hasVideoIDFromPath || hasVideoIDFromQuery

        switch (hasVideoID, hasListParam) {
        case (true, true): return .videoWithPlaylist
        case (true, false): return .singleVideo
        case (false, true): return .playlistOnly
        case (false, false): return .other
        }
    }
}

/// A queued job's lifecycle. Deliberately a plain, no-payload enum (not
/// `.failed(String)`) so it gets free `Codable` synthesis for queue
/// persistence — the failure text lives on `Job.errorMessage` instead,
/// alongside `status == .failed`.
enum JobStatus: String, Codable, Equatable {
    case queued, downloading, converting, completed, failed, cancelled
}

/// One playlist video queued for download+convert. Everything except the
/// mutable status/progress/output fields is captured once, at the moment
/// the job is added to the queue (`AppViewModel.enqueue`) — changing
/// Settings or the main UI's conversion controls afterward must never
/// alter an already-queued job, so nothing here reads live state at
/// processing time. Mirrors the exact set of settings `AppViewModel.
/// RunConfig` (the single-video equivalent) already snapshots.
///
/// Basic- and Advanced-mode jobs resolve their format selector
/// differently at processing time (see `AppViewModel+Queue.swift`'s
/// `processJob`), because Basic mode's actual `conversionMode` isn't
/// knowable until formats are fetched — `BasicModeService.planForPolicy`
/// might return `.none`/`.proRes`/`.h264` depending on what's actually
/// available for that specific video (the same "always end up playable"
/// logic single-video Basic mode already has), whereas Advanced mode's
/// `conversionMode` is fixed by the user regardless of what's available.
/// `isBasicMode` is the discriminator; `conversionMode`/`h264Quality` are
/// only meaningful (used as-is) when it's `false` — a Basic-mode job's
/// real conversion mode is decided fresh by `planForPolicy` every time.
struct Job: Identifiable, Codable, Equatable {
    let id: UUID
    let url: String
    var title: String
    let outputDir: URL
    let isBasicMode: Bool
    /// Advanced-mode's fixed conversion choice — ignored when `isBasicMode`.
    let conversionMode: ConversionMode
    /// Advanced-mode's fixed H.264 quality — ignored when `isBasicMode`.
    let h264Quality: H264Quality
    let proResTier: ProResTier
    /// Basic mode's "Editing quality (ProRes)" toggle — ignored when
    /// `!isBasicMode` (Advanced mode uses `conversionMode` directly).
    let useProResForBasicMode: Bool
    let downscale4K: Bool
    let deleteSourceAfterConversion: Bool
    let useHardwareAcceleration: Bool
    let preferMP4: Bool
    let cookiesFromBrowser: CookieBrowser
    let sleepInterval: Bool
    let formatPolicy: PlaylistFormatPolicy

    var status: JobStatus = .queued
    var errorMessage: String?
    var progressFraction: Double?
    var progressLabel: String = ""
    var progressETA: String?
    var outputURL: URL?
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
