import Foundation

/// Free-space lookups + human-readable byte formatting, used by both the
/// pre-flight "will this conversion fit" warning and the post-hoc
/// disk-full failure alert in AppViewModel. Plain FileManager/URL logic,
/// no subprocess involved — kept separate from FFmpegService for that
/// reason.
enum DiskSpaceService {
    static func availableBytes(at directory: URL) -> Int64? {
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return capacity
    }

    static func volumeName(at directory: URL) -> String? {
        (try? directory.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
