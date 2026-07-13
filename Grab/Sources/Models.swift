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
                    + "(Settings → Update yt-dlp), and/or by enabling \"Use cookies from browser\" in Settings.",
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
