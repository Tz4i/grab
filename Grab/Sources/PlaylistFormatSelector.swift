import Foundation

/// Advanced-mode's format-selection logic for playlist queue jobs — kept
/// separate from `BasicModeService` (whose doc comment and "always end up
/// with a playable file" guarantee are explicitly scoped to Basic mode).
/// Advanced-mode jobs have no such guarantee, matching how Advanced
/// mode's existing single-video flow already has none: the user's own
/// conversion settings (possibly `.none`, keeping the raw downloaded
/// codec as-is) are trusted, not second-guessed.
enum PlaylistFormatSelector {

    /// Picks the highest-resolution video format within `policy`'s height
    /// cap (or the true best if uncapped), paired with yt-dlp's own
    /// `bestaudio` selector — no avc1/AAC preference, no forced re-encode
    /// fallback. Falls back to the uncapped pool when nothing exists at or
    /// below the cap, same reasoning as `BasicModeService.planForPolicy`:
    /// a "best up to X" policy is a ceiling, not a hard requirement.
    static func advancedFormatSelector(formats: [VideoFormat], policy: PlaylistFormatPolicy) -> String? {
        let videoFormats = formats.filter { !$0.isAudioOnly }
        guard !videoFormats.isEmpty else { return nil }

        let pool: [VideoFormat]
        if let cap = policy.heightCap {
            let capped = videoFormats.filter { ($0.resolutionHeight ?? 0) <= cap }
            pool = capped.isEmpty ? videoFormats : capped
        } else {
            pool = videoFormats
        }

        guard let best = pool.max(by: { $0.resolutionPixels < $1.resolutionPixels }) else { return nil }
        return "\(best.id)+bestaudio"
    }
}
