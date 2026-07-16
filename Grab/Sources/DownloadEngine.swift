import Foundation

/// The shared download+convert engine — extracted from what used to be
/// `AppViewModel.runDownloadAndConvert` so the playlist queue can reuse
/// the exact same retry/HDR/disk-space/hardware-fallback logic without
/// duplicating it. `AppViewModel`'s own single-video path calls this with
/// itself as the `sink` (see `AppViewModel`'s `DownloadProgressSink`
/// conformance) — byte-identical observable behavior to before this
/// extraction, just routed through a callback instead of writing directly
/// to `@Published` properties. The playlist queue calls this with a
/// per-job `JobSink` (see `AppViewModel+Queue.swift`) instead.
///
/// `@MainActor`-pinned because the original code ran on `AppViewModel`'s
/// actor (the `Task {}` wrapping it was written directly inside a
/// MainActor method and inherited that isolation) — `sink` calls from
/// inside the output-streaming closures below need the same pinning to
/// type-check against a caller that isn't itself always `self`.
@MainActor
enum DownloadEngine {

    enum Phase {
        case downloading
        case converting
    }

    /// What actually happened, in enough detail for each caller to
    /// reconstruct its own UI response — deliberately *not* a flat
    /// success/error-string pair. The original code is genuinely
    /// asymmetric between the two failure sites (a download failure falls
    /// back to `ActionableAlert`/`classifyFailure` for
    /// `.missingBinary/.invalidInput/.none`; a conversion failure has its
    /// own separate `.invalidInput` message and never calls
    /// `presentActionableAlert` at all) — that asymmetry has to survive
    /// the extraction, and only the single-video caller (which alone
    /// knows about `ActionableAlert`/Settings) should ever build one; the
    /// playlist queue only ever needs a plain string for `Job.
    /// errorMessage` and must never surface an interactive alert.
    enum Outcome {
        /// `modeName` is nil when `conversionMode == .none` (a plain
        /// download, no conversion pass ran) — mirrors the original
        /// code's "Download Complete" vs "<mode> Conversion Complete"
        /// notification-title branch.
        case success(outputURL: URL, modeName: String?)
        case downloadFailed(rawOutput: String, systemFailure: SystemFailureKind)
        case outputPathUndetermined
        case diskSpaceDeclined
        case conversionFailed(
            rawOutput: String,
            systemFailure: SystemFailureKind,
            outputDirectory: URL,
            estimatedRequiredBytes: Int64?,
            modeName: String
        )
    }

    /// Max attempts (initial try + retries) for either auto-retry loop
    /// below (the 403 download retry, the hardware→software conversion
    /// fallback) — moved here from `AppViewModel`, which used to own this
    /// as a private constant; unchanged value/meaning.
    static let maxAttemptsPerPhase = 2

    static func run(
        url: String,
        formatSelector: String,
        outputDir: URL,
        conversionMode: ConversionMode,
        proResTier: ProResTier,
        h264Quality: H264Quality,
        downscale4K: Bool,
        deleteSourceAfterConversion: Bool,
        useHardwareAcceleration: Bool,
        preferMP4: Bool,
        cookiesFromBrowser: CookieBrowser,
        sleepInterval: Bool,
        runner: ProcessRunner,
        sink: DownloadProgressSink
    ) async -> Outcome {
        // Wraps `onOutput` chunks so they always land on the sink via a
        // MainActor hop — `ProcessRunner`'s pipe readability handlers (and
        // its final drain-on-exit) fire from a background
        // `DispatchQueue.global`, not MainActor, same as the original
        // `AppViewModel.streamHandler` this replaces.
        func streamHandler(onChunk: ((String) -> Void)? = nil) -> (String) -> Void {
            { [weak sink] chunk in
                Task { @MainActor in
                    sink?.appendLog(chunk)
                    onChunk?(chunk)
                }
            }
        }

        // Tries the given format selector. Used for the initial attempt and
        // for the automatic 403 fallback retry below — identical flags
        // either time, only -f differs.
        func attemptDownload(selector: String) async -> ProcessResult {
            let args = YTDLPService.downloadArguments(
                url: url, formatSelector: selector, outputDir: outputDir,
                preferMP4: preferMP4, cookiesFromBrowser: cookiesFromBrowser, sleepInterval: sleepInterval
            )
            sink.setProgressLabel("Downloading…")
            sink.setProgressFraction(nil)
            sink.setProgressETA(nil)
            sink.appendLog("\n$ yt-dlp \(args.joined(separator: " "))\n")
            return await runner.run(
                path: Tool.ytdlp,
                arguments: args,
                qos: .userInitiated,
                onOutput: streamHandler(onChunk: { [weak sink] chunk in
                    guard let progress = YTDLPService.parseDownloadProgress(from: chunk) else { return }
                    sink?.setProgressFraction(progress.fraction)
                    sink?.setProgressETA(progress.eta)
                })
            )
        }

        // Bounded retry loop (see maxAttemptsPerPhase): a genuinely transient
        // failure (HTTP 403) gets one automatic retry with a simpler format
        // selector. Anything SystemFailureKind recognizes as fatal (disk
        // full, permission denied, missing binary) never retries at all —
        // retrying those can only ever fail again.
        var currentSelector = formatSelector
        var downloadAttempts = 0
        var downloadResult: ProcessResult
        repeat {
            downloadAttempts += 1
            downloadResult = await attemptDownload(selector: currentSelector)
            guard downloadResult.exitCode != 0 else { break }

            let systemFailure = SystemFailureKind.classify(downloadResult.output)
            guard !systemFailure.isFatal,
                  downloadAttempts < maxAttemptsPerPhase,
                  currentSelector != YTDLPService.fallbackFormatSelector,
                  YTDLPService.classifyFailure(downloadResult.output) == .forbidden403
            else { break }

            sink.appendLog(
                "\nDownload failed with HTTP 403 — automatically retrying once with a simpler format "
                + "selection (\(YTDLPService.fallbackFormatSelector))…\n"
            )
            currentSelector = YTDLPService.fallbackFormatSelector
        } while true

        guard downloadResult.exitCode == 0 else {
            sink.appendLog("\nyt-dlp exited with code \(downloadResult.exitCode).\n")
            return .downloadFailed(
                rawOutput: downloadResult.output,
                systemFailure: SystemFailureKind.classify(downloadResult.output)
            )
        }

        guard let outputPath = YTDLPService.extractOutputFile(from: downloadResult.output) else {
            sink.appendLog("\nDownload finished but the output file path could not be determined.\n")
            return .outputPathUndetermined
        }
        sink.appendLog("\nDownloaded: \(outputPath)\n")
        sink.setProgressFraction(nil)
        sink.setProgressETA(nil)

        let inputURL = URL(fileURLWithPath: outputPath)

        // Always inspect the source's color metadata (read-only, cheap) so
        // the "detected source" indicator has something to show even when
        // ProRes conversion itself is off this run.
        sink.setProgressLabel("Inspecting color metadata…")
        sink.appendLog("\n$ ffprobe -show_entries stream=color_transfer,color_primaries \"\(inputURL.lastPathComponent)\"\n")

        let colorResult = await FFmpegService.probeColorInfo(fileURL: inputURL, runner: runner)
        let colorInfo: ColorInfo
        switch colorResult {
        case .success(let info):
            colorInfo = info
        case .failure(let error):
            sink.appendLog("\nffprobe failed: \(error.message)\nDefaulting to SDR path.\n")
            colorInfo = ColorInfo(transfer: "unknown", primaries: "unknown")
        }
        sink.appendLog("\nColor metadata: \(colorInfo.summary)\n")
        sink.setColorInfo(colorInfo)

        guard conversionMode != .none else {
            return .success(outputURL: inputURL, modeName: nil)
        }

        let isH264 = conversionMode == .h264
        let modeName = isH264 ? "H.264" : "ProRes"
        let outputURL = isH264
            ? FFmpegService.h264OutputURL(for: inputURL)
            : FFmpegService.proResOutputURL(for: inputURL)
        let usedHDRPath = colorInfo.isHDR

        sink.appendLog(usedHDRPath
            ? "Detected HDR (PQ/BT.2020) — using HDR tone-map filter chain.\n"
            : "Detected SDR (bt709 / unspecified) — using direct SDR path.\n")
        if usedHDRPath && useHardwareAcceleration {
            sink.appendLog("Note: the HDR tone-map filter chain (zscale/tonemap) runs on the CPU regardless of "
                + "hardware acceleration — only the final \(modeName) encode step uses the hardware encoder.\n")
        }

        // Best-effort duration probe purely for the progress bar; a failure
        // here just means an indeterminate progress bar, nothing else. Uses
        // the same shared `runner` as everything else so Cancel still works
        // correctly if it lands while this quick probe is in flight.
        var sourceDuration: TimeInterval?
        if case .success(let duration) = await FFmpegService.probeDuration(fileURL: inputURL, runner: runner) {
            sourceDuration = duration
        }

        // Pre-flight disk-space check: estimate the output size from
        // duration/resolution/fps/codec-tier and compare against free space
        // on the output volume, warning (with a Continue/Cancel choice, via
        // the sink) before spending minutes encoding something that can't
        // fit. Best-effort like the duration probe above — if either probe
        // fails, there's nothing to estimate against, so this just skips
        // silently rather than blocking the run.
        var estimatedRequiredBytes: Int64?
        if let duration = sourceDuration,
           case .success(let dimensions) = await FFmpegService.probeVideoDimensions(fileURL: inputURL, runner: runner) {
            let requiredBytes = FFmpegService.estimateOutputBytes(
                durationSeconds: duration, conversionMode: conversionMode, proResTier: proResTier,
                h264Quality: h264Quality, width: dimensions.width, height: dimensions.height, fps: dimensions.fps
            )
            estimatedRequiredBytes = requiredBytes
            let proceed = await sink.confirmEnoughDiskSpace(
                requiredBytes: requiredBytes, at: outputURL.deletingLastPathComponent()
            )
            guard proceed else {
                sink.appendLog("\nConversion cancelled by user (not enough free space).\n")
                return .diskSpaceDeclined
            }
        }

        sink.setPhase(.converting)

        // Tries the hardware encoder (prores_videotoolbox / h264_videotoolbox)
        // or its software counterpart (prores_ks / libx264) depending on
        // `useHardware`. Filter chain is identical either way for both
        // modes; only the rate-control flags differ between H.264's
        // hardware (bitrate) and software (CRF) paths.
        func attemptConversion(useHardware: Bool) async -> ProcessResult {
            let args: [String]
            let encoderName: String
            if isH264 {
                (args, _) = FFmpegService.h264ConversionArguments(
                    inputURL: inputURL, outputURL: outputURL, colorInfo: colorInfo,
                    quality: h264Quality, downscale4K: downscale4K, useHardwareEncoder: useHardware
                )
                encoderName = useHardware ? FFmpegService.h264HardwareEncoder : FFmpegService.h264SoftwareEncoder
            } else {
                (args, _) = FFmpegService.conversionArguments(
                    inputURL: inputURL, outputURL: outputURL, colorInfo: colorInfo,
                    tier: proResTier, downscale4K: downscale4K, useHardwareEncoder: useHardware
                )
                encoderName = useHardware ? FFmpegService.hardwareEncoder : FFmpegService.softwareEncoder
            }

            sink.setProgressFraction(nil)
            sink.setProgressETA(nil)
            sink.setProgressLabel(usedHDRPath
                ? "Converting to \(modeName) (\(encoderName), HDR tone-map)…"
                : "Converting to \(modeName) (\(encoderName))…")
            sink.appendLog("\n$ ffmpeg \(args.joined(separator: " "))\n")

            let conversionStart = Date()
            return await runner.run(
                path: Tool.ffmpeg,
                arguments: args,
                qos: .userInitiated,
                onOutput: streamHandler(onChunk: { [weak sink] chunk in
                    guard let duration = sourceDuration,
                          let currentTime = FFmpegService.parseTimeSeconds(from: chunk) else { return }
                    let fraction = min(max(currentTime / duration, 0), 1)
                    sink?.setProgressFraction(fraction)

                    let remaining = max(duration - currentTime, 0)
                    if let speed = FFmpegService.parseSpeed(from: chunk), speed > 0 {
                        sink?.setProgressETA(FFmpegService.formatDuration(remaining / speed))
                    } else if fraction > 0 {
                        let elapsed = Date().timeIntervalSince(conversionStart)
                        sink?.setProgressETA(FFmpegService.formatDuration(elapsed / fraction * (1 - fraction)))
                    }
                    // If neither branch applies (fraction == 0, no speed
                    // yet), deliberately leave the ETA untouched rather
                    // than resetting it — matches the pre-extraction
                    // behavior exactly (only ever written inside these two
                    // branches, never reset to nil here).
                })
            )
        }

        // Bounded to maxAttemptsPerPhase (hardware attempt + at most one
        // software retry) same as the download loop above. The fallback
        // only fires when the hardware failure isn't one of
        // SystemFailureKind's fatal categories — a disk-full or
        // permission-denied failure will fail identically on the software
        // encoder, so retrying just burns another full encode's worth of
        // CPU/IO for a result that was never going to succeed.
        var convertResult = await attemptConversion(useHardware: useHardwareAcceleration)
        var conversionAttempts = 1

        if useHardwareAcceleration && convertResult.exitCode != 0 && conversionAttempts < maxAttemptsPerPhase {
            let systemFailure = SystemFailureKind.classify(convertResult.output)
            if systemFailure.isFatal {
                sink.appendLog("\nHardware encoder failed with a non-retryable error — not falling back to software encoding (see error below).\n")
            } else {
                let hardwareEncoder = isH264 ? FFmpegService.h264HardwareEncoder : FFmpegService.hardwareEncoder
                let softwareEncoder = isH264 ? FFmpegService.h264SoftwareEncoder : FFmpegService.softwareEncoder
                sink.appendLog(
                    "\nHardware encoder (\(hardwareEncoder)) failed (exit code \(convertResult.exitCode))"
                    + " — falling back to software encoder (\(softwareEncoder)).\n"
                )
                conversionAttempts += 1
                convertResult = await attemptConversion(useHardware: false)
            }
        }

        if convertResult.exitCode == 0 {
            sink.appendLog("\n\(modeName) conversion complete: \(outputURL.path)\n")

            if !isH264, case .success(let tag) = await FFmpegService.probeCodecTag(fileURL: outputURL, runner: runner) {
                sink.appendLog("Output codec tag: \(tag) (expected apcn for 422, apch for 422 HQ)\n")
            }

            if deleteSourceAfterConversion {
                do {
                    try FileManager.default.removeItem(at: inputURL)
                    sink.appendLog("Deleted source file: \(inputURL.path)\n")
                } catch {
                    sink.appendLog("Could not delete source file: \(error.localizedDescription)\n")
                }
            }

            return .success(outputURL: outputURL, modeName: modeName)
        } else {
            sink.appendLog("\nffmpeg exited with code \(convertResult.exitCode).\n")
            return .conversionFailed(
                rawOutput: convertResult.output,
                systemFailure: SystemFailureKind.classify(convertResult.output),
                outputDirectory: outputURL.deletingLastPathComponent(),
                estimatedRequiredBytes: estimatedRequiredBytes,
                modeName: modeName
            )
        }
    }
}

/// The callback surface `DownloadEngine.run` reports through instead of
/// writing directly to `@Published` properties — `AppViewModel` conforms
/// for the single-video path (delegating to its existing private
/// `appendLog`/`confirmEnoughDiskSpace` methods and `@Published`
/// properties, `setPhase` a no-op); the playlist queue's `JobSink`
/// conforms for queued jobs, writing into a specific `Job`'s fields
/// instead — see `AppViewModel+Queue.swift`.
@MainActor
protocol DownloadProgressSink: AnyObject {
    func setPhase(_ phase: DownloadEngine.Phase)
    func setProgressLabel(_ label: String)
    func setProgressFraction(_ fraction: Double?)
    func setProgressETA(_ eta: String?)
    func appendLog(_ text: String)
    func setColorInfo(_ info: ColorInfo?)
    /// Queue jobs must never pop an interactive alert mid-batch — `JobSink`
    /// always returns `true` immediately here; a real out-of-space failure
    /// still surfaces later as a normal `.conversionFailed` outcome. The
    /// single-video path (`AppViewModel`) delegates to its existing
    /// Continue/Cancel alert flow, unchanged.
    func confirmEnoughDiskSpace(requiredBytes: Int64, at directory: URL) async -> Bool
}
