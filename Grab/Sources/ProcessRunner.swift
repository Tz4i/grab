import Foundation

struct ProcessResult {
    let exitCode: Int32
    let output: String
}

/// Locks its own mutable state so it can be safely captured by the
/// concurrently-invoked pipe/termination callbacks below.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = ""
    private var didFinish = false

    func append(_ str: String) {
        lock.lock()
        collected += str
        lock.unlock()
    }

    /// Returns the collected output the first time this is called; nil on
    /// any subsequent call, so a duplicate termination/error path can't
    /// resume the continuation twice.
    func finishOnce() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return nil }
        didFinish = true
        return collected
    }
}

/// Wraps `Process` to run Homebrew CLI tools by absolute path, off the main
/// thread, streaming combined stdout/stderr to a callback while also
/// collecting the full output for callers that need it (e.g. ffprobe JSON).
final class ProcessRunner {
    private var process: Process?
    private let stateLock = NSLock()

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return process?.isRunning ?? false
    }

    @discardableResult
    func run(
        path: String,
        arguments: [String],
        qos: QualityOfService = .userInitiated,
        onOutput: ((String) -> Void)? = nil
    ) async -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            let msg = "ERROR: required tool not found at \(path)\n"
            onOutput?(msg)
            return ProcessResult(exitCode: -1, output: msg)
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.qualityOfService = qos
            process.environment = Self.environmentWithHomebrewPath()

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let state = RunState()

            @Sendable func finish(_ code: Int32) {
                // Stop the async callbacks first...
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                // ...then do one final synchronous drain of each pipe. Child
                // processes (yt-dlp/Python in particular) fully block-buffer
                // stdout when it's not a TTY, so a burst of output can be
                // sitting in the pipe, flushed right as the process exits.
                // Without this, `terminationHandler` can race the readability
                // handler and silently drop that final chunk (verified: this
                // was previously eating yt-dlp's last `[download]`/`[Merger]`
                // lines on short-lived downloads). The child has already
                // exited here, so the write end is closed and this reads
                // whatever's left then hits EOF — it does not block.
                for pipe in [outPipe, errPipe] {
                    if let remaining = try? pipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
                        let str = String(decoding: remaining, as: UTF8.self)
                        state.append(str)
                        onOutput?(str)
                    }
                }

                guard let out = state.finishOnce() else { return }
                continuation.resume(returning: ProcessResult(exitCode: code, output: out))
            }

            for pipe in [outPipe, errPipe] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    let str = String(decoding: data, as: UTF8.self)
                    state.append(str)
                    onOutput?(str)
                }
            }

            process.terminationHandler = { proc in
                finish(proc.terminationStatus)
            }

            self.stateLock.lock()
            self.process = process
            self.stateLock.unlock()

            DispatchQueue.global(qos: qos.dispatchQoS).async {
                do {
                    try process.run()
                } catch {
                    let msg = "ERROR: failed to launch \(path): \(error.localizedDescription)\n"
                    state.append(msg)
                    onOutput?(msg)
                    finish(-1)
                }
            }
        }
    }

    func cancel() {
        stateLock.lock()
        let proc = process
        stateLock.unlock()
        proc?.terminate()
    }

    /// GUI apps don't inherit the shell's PATH, so tools that shell out to
    /// other tools (yt-dlp calling ffmpeg to merge streams) can fail to find
    /// them even though we launch yt-dlp itself by absolute path. Belt and
    /// braces alongside passing `--ffmpeg-location` explicitly. Both
    /// Homebrew prefixes are prepended (not just whichever one resolved a
    /// binary) since Rosetta/mixed installs can have tools split across
    /// both `/opt/homebrew` and `/usr/local`.
    private static func environmentWithHomebrewPath() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? ""
        var components = existing.split(separator: ":").map(String.init)
        for prefix in Tool.searchPrefixes.reversed() where !components.contains(prefix) {
            components.insert(prefix, at: 0)
        }
        environment["PATH"] = components.joined(separator: ":")
        return environment
    }
}

private extension QualityOfService {
    var dispatchQoS: DispatchQoS.QoSClass {
        switch self {
        case .userInteractive: return .userInteractive
        case .userInitiated: return .userInitiated
        case .utility: return .utility
        case .background: return .background
        default: return .default
        }
    }
}
