import Foundation

/// Line-oriented log buffer used by AppViewModel to keep the in-app log
/// from growing unbounded during long ffmpeg encodes (which emit a
/// `frame=...` status line per progress tick — thousands of lines for a
/// long clip) or long yt-dlp downloads. Two things keep it bounded:
/// capping at `maxLines` complete lines (oldest dropped first), and
/// collapsing consecutive `frame=` progress lines into a single
/// "current progress" line instead of appending each one as a new row.
struct LogBuffer {
    private(set) var lines: [String] = []
    private var partialLine: String = ""
    let maxLines: Int

    init(maxLines: Int = 500) {
        self.maxLines = maxLines
    }

    /// Feeds a raw chunk of process output — which may contain zero, one,
    /// or several newlines, and may split a single line across two calls
    /// (chunks arrive as whatever `Pipe` handed back, not line-buffered).
    mutating func feed(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        var pieces = (partialLine + chunk).components(separatedBy: "\n")
        partialLine = pieces.removeLast()
        for line in pieces {
            appendLine(line)
        }
    }

    private mutating func appendLine(_ line: String) {
        if isProgressLine(line), let last = lines.last, isProgressLine(last) {
            lines[lines.count - 1] = line
        } else {
            lines.append(line)
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    private func isProgressLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("frame=")
    }

    /// The full text to display, including whatever's been received since
    /// the last complete line (a partial line with no trailing newline yet
    /// — e.g. output flushed right before the process exits).
    var text: String {
        partialLine.isEmpty ? lines.joined(separator: "\n") : (lines + [partialLine]).joined(separator: "\n")
    }
}
