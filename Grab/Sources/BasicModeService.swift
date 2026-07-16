import Foundation

/// Pure format-selection logic for Basic mode — no SwiftUI/AppKit
/// dependency, harness-testable like YTDLPService/FFmpegService (see
/// CLAUDE.md's "The actually-useful verification method"). Given the
/// formats already fetched for a URL, decides which resolutions to offer
/// and, once the user picks one, exactly which format(s) to download and
/// whether a conversion pass is required.
///
/// The guiding principle (CLAUDE.md): a Basic-mode user must never end up
/// with a file they can't double-click and play. H.264 (avc1) + AAC is
/// downloaded directly with no re-encode wherever YouTube provides it
/// (720p/1080p); everything else is re-encoded to H.264 so the output is
/// guaranteed to open in QuickTime.
enum BasicModeService {

    /// Which resolution choices to show in the picker sheet — only
    /// resolutions with an actually-available matching format, in a fixed
    /// 720p -> 1080p -> 4K -> Best available order. "Best available" is
    /// always included once any video format exists.
    static func availableResolutionChoices(formats: [VideoFormat]) -> [BasicResolutionChoice] {
        let videoFormats = formats.filter { !$0.isAudioOnly }
        guard !videoFormats.isEmpty else { return [] }

        var choices = [BasicResolutionChoice.p720, .p1080, .p2160].filter { target in
            videoFormats.contains { $0.resolutionHeight == target.rawValue }
        }
        choices.append(.best)
        return choices
    }

    /// QuickTime can't reliably play Opus audio, and yt-dlp's "bestaudio"
    /// selector often prefers Opus over AAC — so the direct-download
    /// (no-conversion) path needs an explicit AAC/m4a pick rather than
    /// "bestaudio" to guarantee the merged mp4 actually opens in
    /// QuickTime. Picks the last matching format, matching this file's
    /// existing convention (YTDLPService/ContentView) of treating yt-dlp's
    /// -F listing order as ascending quality.
    private static func bestAACAudio(in formats: [VideoFormat]) -> VideoFormat? {
        formats.last { $0.isAudioOnly && $0.acodec.lowercased().hasPrefix("mp4a") }
    }

    /// Builds the concrete download+convert plan for a resolution choice.
    /// Returns nil only if `formats` has no video formats at all, or (for
    /// a specific resolution) none matching that height — which shouldn't
    /// happen in practice since the sheet only offers choices returned by
    /// `availableResolutionChoices` above. `proResTier` is only meaningful
    /// when `useProRes` is true; ignored otherwise (mirrors `h264Quality`
    /// being a harmless placeholder in the ProRes branch below).
    static func plan(
        for choice: BasicResolutionChoice,
        formats: [VideoFormat],
        useProRes: Bool,
        proResTier: ProResTier
    ) -> BasicDownloadPlan? {
        let videoFormats = formats.filter { !$0.isAudioOnly }
        guard !videoFormats.isEmpty else { return nil }

        let candidates: [VideoFormat]
        switch choice {
        case .best:
            // "Best available" means best *resolution*, not best codec --
            // pin down the actual target pixel count first, then apply the
            // same H.264-preference logic below only within that tier.
            // Without this, `candidates.last(where: avc1)` would search
            // across every resolution and could silently substitute a
            // lower-resolution H.264 stream (e.g. 1080p) for a higher-
            // resolution VP9/AV1 one (e.g. 2160p) instead of converting the
            // true best source -- caught by the standalone harness, not
            // obvious from reading the code alone.
            guard let overallBest = videoFormats.max(by: { $0.resolutionPixels < $1.resolutionPixels }) else { return nil }
            candidates = videoFormats.filter { $0.resolutionPixels == overallBest.resolutionPixels }
        case .p720, .p1080, .p2160:
            candidates = videoFormats.filter { $0.resolutionHeight == choice.rawValue }
        }
        guard !candidates.isEmpty else { return nil }

        return planFromCandidates(candidates, allFormats: formats, useProRes: useProRes, proResTier: proResTier)
    }

    /// Same "always end up with a playable file" decision as `plan(for:)`
    /// above, but for a playlist queue job: `candidates` is pre-filtered
    /// by `PlaylistFormatPolicy.heightCap` (a ceiling, not an exact match)
    /// instead of an exact resolution choice. Falls back to the *uncapped*
    /// pool when nothing exists at or below the cap (rare — a video whose
    /// smallest format still exceeds the cap) rather than failing the job
    /// outright, since "best up to 1080p" reads as a ceiling on quality,
    /// not a hard requirement the video must satisfy or be skipped.
    static func planForPolicy(
        formats: [VideoFormat],
        policy: PlaylistFormatPolicy,
        useProRes: Bool,
        proResTier: ProResTier
    ) -> BasicDownloadPlan? {
        let videoFormats = formats.filter { !$0.isAudioOnly }
        guard !videoFormats.isEmpty else { return nil }

        let pool: [VideoFormat]
        if let cap = policy.heightCap {
            let capped = videoFormats.filter { ($0.resolutionHeight ?? 0) <= cap }
            pool = capped.isEmpty ? videoFormats : capped
        } else {
            pool = videoFormats
        }

        guard let overallBest = pool.max(by: { $0.resolutionPixels < $1.resolutionPixels }) else { return nil }
        let candidates = pool.filter { $0.resolutionPixels == overallBest.resolutionPixels }
        guard !candidates.isEmpty else { return nil }

        return planFromCandidates(candidates, allFormats: formats, useProRes: useProRes, proResTier: proResTier)
    }

    /// Shared tail of `plan(for:)`/`planForPolicy` once a resolution tier's
    /// `candidates` (all formats at the same target pixel count) has been
    /// decided — the actual "always end up with a playable file"
    /// guarantee: ProRes always re-encodes regardless of source codec;
    /// otherwise prefer a direct H.264+AAC download with no re-encode, and
    /// only fall back to a forced H.264 re-encode when no such source
    /// exists at this tier.
    private static func planFromCandidates(
        _ candidates: [VideoFormat],
        allFormats: [VideoFormat],
        useProRes: Bool,
        proResTier: ProResTier
    ) -> BasicDownloadPlan? {
        if useProRes {
            // Convert to the chosen ProRes tier regardless of resolution/
            // source codec — container/codec of the source doesn't matter
            // since ffmpeg re-encodes it either way.
            guard let video = candidates.max(by: { $0.resolutionPixels < $1.resolutionPixels }) else { return nil }
            return BasicDownloadPlan(
                formatSelector: "\(video.id)+bestaudio",
                conversionMode: .proRes,
                h264Quality: .high,
                proResTier: proResTier
            )
        }

        // Prefer an H.264 (avc1) source at this resolution paired with AAC
        // audio: plays in QuickTime with no re-encode, no quality loss, no
        // wait.
        if let h264Video = candidates.last(where: { $0.vcodec.lowercased().hasPrefix("avc1") }),
           let aacAudio = bestAACAudio(in: allFormats) {
            return BasicDownloadPlan(
                formatSelector: "\(h264Video.id)+\(aacAudio.id)",
                conversionMode: .none,
                h264Quality: .high,
                proResTier: .basicModeDefault
            )
        }

        // No H.264 (+ AAC) source at this resolution — always true above
        // 1080p, since YouTube only serves VP9/AV1 there, and possible in
        // principle at 720p/1080p too. Download the best available source
        // and re-encode to H.264 so the output is still guaranteed to open
        // in QuickTime.
        guard let bestVideo = candidates.max(by: { $0.resolutionPixels < $1.resolutionPixels }) else { return nil }
        return BasicDownloadPlan(
            formatSelector: "\(bestVideo.id)+bestaudio",
            conversionMode: .h264,
            h264Quality: .high,
            proResTier: .basicModeDefault
        )
    }
}
