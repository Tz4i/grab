import Foundation

struct AppUpdateInfo: Equatable {
    let version: String
    let url: URL
}

/// Checks GitHub Releases for a newer tagged version than the running
/// build. Deliberately does **not** download/replace the app binary —
/// Grab is unsigned, so a self-replaced copy would just be re-quarantined
/// by Gatekeeper and need the same `xattr -rc` workaround on every update
/// (see README). Linking to the release page is the whole feature.
enum AppUpdateService {
    private static let releasesURL = URL(string: "https://api.github.com/repos/Tz4i/grab/releases/latest")!

    /// Silent on any failure (offline, rate-limited, private repo with no
    /// releases visible unauthenticated, malformed JSON) — this is a
    /// best-effort launch check, never worth surfacing an error for and
    /// never allowed to block launch. `Tz4i/grab` must be a public repo for
    /// this to ever succeed; the GitHub REST API won't return releases from
    /// a private repo without an authenticated request.
    static func checkForUpdate() async -> AppUpdateInfo? {
        var request = URLRequest(url: releasesURL)
        request.setValue("Grab-macOS-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        else { return nil }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard VersionCompare.isNewer(release.tagName, than: currentVersion) else { return nil }

        return AppUpdateInfo(version: release.tagName, url: release.htmlURL)
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// Plain dot-separated version comparison shared by the app-update check
/// (semver-ish tags like "v1.0.0") and would work equally for yt-dlp's
/// calendar versioning ("2026.07.04") if ever needed there — not currently
/// used for yt-dlp since `brew outdated` already computes that itself.
enum VersionCompare {
    static func isNewer(_ a: String, than b: String) -> Bool {
        let partsA = components(of: a)
        let partsB = components(of: b)
        for i in 0..<max(partsA.count, partsB.count) {
            let x = i < partsA.count ? partsA[i] : 0
            let y = i < partsB.count ? partsB[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        var stripped = version
        if stripped.hasPrefix("v") || stripped.hasPrefix("V") {
            stripped.removeFirst()
        }
        return stripped.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
