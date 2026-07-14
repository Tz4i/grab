import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var urlString: String = ""
    @Published var formats: [VideoFormat] = []
    /// The fetched video's title/thumbnail/duration/channel — populated by
    /// the same `-J` call that fetches `formats` (see YTDLPService.
    /// fetchFormats). Deliberately not cleared by `beginDownload`, so the
    /// title/thumbnail stay visible through the download and conversion
    /// phases, confirming which video the progress bar refers to.
    @Published var videoMetadata: VideoMetadata?
    @Published var selectedVideoID: String?
    @Published var selectedAudioID: String?

    /// Persisted directly via UserDefaults (rather than the @AppStorage
    /// property wrapper, which is meant for View/App types) so this stays
    /// owned by the view model exactly as before, but survives relaunch.
    @Published var useBestAudio: Bool = UserDefaults.standard.object(forKey: "useBestAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useBestAudio, forKey: "useBestAudio") }
    }

    @Published var isFetchingFormats = false
    @Published var isRunning = false
    @Published var progressLabel: String = ""
    @Published var progressFraction: Double?
    @Published var progressETA: String?
    @Published var log: String = ""
    @Published var lastError: String?
    @Published var missingToolAlert: Tool.Missing?
    @Published var detectedColorInfo: ColorInfo?
    @Published var actionableAlert: ActionableAlert?
    @Published var ytdlpVersion: String?
    /// The final output file from the last successful job — the ProRes
    /// .mov if conversion ran, otherwise the downloaded file. Drives the
    /// "Reveal in Finder" button; nil until a job actually completes.
    @Published var lastOutputURL: URL?

    /// Both update banners: nil means "don't show" — either no update is
    /// available, the check hasn't completed yet, the check failed (handled
    /// silently, see AppUpdateService/YTDLPService.checkForUpdate), or the
    /// user dismissed the banner this session. Not persisted — a fresh
    /// launch re-checks and re-shows if still applicable, which is the
    /// point of an update nag.
    @Published var ytdlpUpdateInfo: YTDLPUpdateInfo?
    @Published var appUpdateInfo: AppUpdateInfo?
    @Published var isUpdatingYTDLPFromBanner = false

    /// Set when a pre-flight disk-space estimate comes up short, right
    /// before a conversion would start — the UI presents this as a
    /// Continue/Cancel alert and `resolveDiskSpaceWarning` resumes
    /// `diskSpaceContinuation` with the user's choice.
    @Published var diskSpaceWarning: DiskSpaceWarning?
    private var diskSpaceContinuation: CheckedContinuation<Bool, Never>?

    var isBusy: Bool { isFetchingFormats || isRunning }

    /// Max attempts (initial try + retries) for any single auto-retry loop
    /// below (the 403 download retry, the hardware->software conversion
    /// fallback) — a hard backstop so a future classification bug can
    /// never turn into an unbounded retry loop, independent of whichever
    /// per-error-kind logic decides *whether* to retry at all.
    private let maxAttemptsPerPhase = 2

    private let runner = ProcessRunner()
    private var logBuffer = LogBuffer()
    private var logFlushPending = false

    private func appendLog(_ text: String) {
        logBuffer.feed(text)
        scheduleLogFlush()
    }

    /// Batches @Published `log` updates instead of publishing on every
    /// single appended line — ffmpeg can emit a status line many times a
    /// second, and republishing (and re-rendering the log's Text view) on
    /// every one of them is wasted work once the buffer is already
    /// collapsing/capping the underlying lines.
    private func scheduleLogFlush() {
        guard !logFlushPending else { return }
        logFlushPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            self.logFlushPending = false
            self.log = self.logBuffer.text
        }
    }

    private func flushLogNow() {
        logFlushPending = false
        log = logBuffer.text
    }

    /// Awaits the user's Continue/Cancel choice from a `DiskSpaceWarning`
    /// alert. `requiredBytes` is the pre-flight estimate; if the available
    /// space can't be determined at all, or is enough, this resolves
    /// `true` immediately with no prompt.
    private func confirmEnoughDiskSpace(requiredBytes: Int64, at directory: URL) async -> Bool {
        guard let available = DiskSpaceService.availableBytes(at: directory), requiredBytes > available else {
            return true
        }
        let driveName = DiskSpaceService.volumeName(at: directory) ?? "the output drive"
        let message = "Estimated output size is \(DiskSpaceService.formatBytes(requiredBytes)), but only "
            + "\(DiskSpaceService.formatBytes(available)) is free on \(driveName). The conversion will likely "
            + "run out of space partway through. Continue anyway?"
        return await withCheckedContinuation { continuation in
            diskSpaceContinuation = continuation
            diskSpaceWarning = DiskSpaceWarning(message: message)
        }
    }

    func resolveDiskSpaceWarning(proceed: Bool) {
        diskSpaceWarning = nil
        diskSpaceContinuation?.resume(returning: proceed)
        diskSpaceContinuation = nil
    }

    /// Builds a "not enough free space" message for the disk-full failure
    /// alert — used both when the pre-flight estimate is unavailable (no
    /// duration/dimensions probe) and when ffmpeg/yt-dlp actually hits
    /// ENOSPC. Includes the estimate only when the caller has one.
    private func diskFullMessage(at directory: URL, estimatedRequiredBytes: Int64?) -> String {
        let driveName = DiskSpaceService.volumeName(at: directory) ?? "the output drive"
        var message = "Not enough free space on \(driveName) to complete the operation."
        if let estimatedRequiredBytes {
            message += " Estimated \(DiskSpaceService.formatBytes(estimatedRequiredBytes)) needed"
            if let available = DiskSpaceService.availableBytes(at: directory) {
                message += ", \(DiskSpaceService.formatBytes(available)) available."
            } else {
                message += "."
            }
        } else if let available = DiskSpaceService.availableBytes(at: directory) {
            message += " \(DiskSpaceService.formatBytes(available)) available."
        }
        return message
    }

    private func streamHandler(onChunk: ((String) -> Void)? = nil) -> (String) -> Void {
        { [weak self] chunk in
            Task { @MainActor in
                self?.appendLog(chunk)
                onChunk?(chunk)
            }
        }
    }

    /// Picks the highest-resolution video format and enables best-audio,
    /// mirroring exactly what manually clicking those same controls would
    /// set — no new selection state, no effect on the download command.
    func selectBestQuality() {
        guard let best = formats.filter({ !$0.isAudioOnly }).max(by: { $0.resolutionPixels < $1.resolutionPixels }) else {
            return
        }
        selectedVideoID = best.id
        useBestAudio = true
    }

    /// Runs `yt-dlp --version` once (independent ProcessRunner, since this
    /// is a read-only side query that shouldn't interact with Cancel or any
    /// in-flight fetch/download). Intended to be called once on launch.
    func checkYTDLPVersion() {
        Task {
            ytdlpVersion = await YTDLPService.fetchVersion(runner: ProcessRunner())
        }
    }

    /// Fires both update checks independently and never awaits either —
    /// callers (ContentView's launch `.task`) must not block on this.
    /// Each check is separately silent-on-failure internally; nothing here
    /// needs its own error handling.
    func checkForUpdates() {
        Task {
            ytdlpUpdateInfo = await YTDLPService.checkForUpdate(runner: ProcessRunner())
        }
        Task {
            appUpdateInfo = await AppUpdateService.checkForUpdate()
        }
    }

    /// Runs `brew upgrade yt-dlp` from the update banner specifically (as
    /// opposed to Settings' identical-in-spirit button) — kept as its own
    /// method rather than reusing SettingsView's local one since that one
    /// is deliberately self-contained/not wired to AppViewModel (see
    /// CLAUDE.md's "SettingsView is deliberately self-contained" note).
    func updateYTDLPFromBanner() async {
        isUpdatingYTDLPFromBanner = true
        _ = await ProcessRunner().run(path: Tool.brew, arguments: ["upgrade", "yt-dlp"], qos: .utility)
        isUpdatingYTDLPFromBanner = false
        ytdlpUpdateInfo = nil
        checkYTDLPVersion()
    }

    private func presentActionableAlert(for rawOutput: String) {
        actionableAlert = ActionableAlert.make(for: YTDLPService.classifyFailure(rawOutput))
    }

    // MARK: - Fetch formats

    func fetchFormats(cookiesFromBrowser: CookieBrowser) {
        Task { await performFetchFormats(cookiesFromBrowser: cookiesFromBrowser) }
    }

    /// Same fetch as the Advanced-mode toolbar button above, but awaitable.
    /// Basic mode's single "Download" action needs to know exactly when
    /// the silent background fetch finishes so it can open the
    /// resolution-picker sheet (see CLAUDE.md's "Basic mode flow" —
    /// "Fetch formats silently in the background — no separate 'Fetch
    /// Formats' step").
    @discardableResult
    func fetchFormatsAwaiting(cookiesFromBrowser: CookieBrowser) async -> Bool {
        await performFetchFormats(cookiesFromBrowser: cookiesFromBrowser)
    }

    private func performFetchFormats(cookiesFromBrowser: CookieBrowser) async -> Bool {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return false }

        if let missing = Tool.missingTools().first(where: { $0.name == "yt-dlp" }) {
            missingToolAlert = missing
            return false
        }

        formats = []
        videoMetadata = nil
        selectedVideoID = nil
        selectedAudioID = nil
        lastError = nil
        actionableAlert = nil
        detectedColorInfo = nil
        progressFraction = nil
        progressETA = nil
        isFetchingFormats = true
        progressLabel = "Fetching video info…"
        appendLog("$ yt-dlp -J --no-playlist --no-warnings \"\(trimmedURL)\"\n")

        // Deliberately not streamed into the log via streamHandler() — the
        // -J call's whole stdout is one JSON blob (tens of KB), not
        // line-oriented progress output like -F's table or a download's
        // [download] lines, so dumping it into the log would just be noise.
        let result = await YTDLPService.fetchFormats(
            url: trimmedURL,
            cookiesFromBrowser: cookiesFromBrowser,
            runner: runner,
            onOutput: { _ in }
        )
        isFetchingFormats = false
        progressLabel = ""

        let success: Bool
        switch result {
        case .success(let fetched):
            videoMetadata = fetched.metadata
            formats = fetched.formats
            selectedVideoID = fetched.formats.first(where: { !$0.isAudioOnly })?.id
            selectedAudioID = fetched.formats.first(where: { $0.isAudioOnly })?.id
            appendLog("\nFound \"\(fetched.metadata.title)\" — \(fetched.formats.count) format(s).\n")
            success = true
        case .failure(let error):
            appendLog("\nyt-dlp failed:\n\(error.message)\n")
            lastError = error.message
            presentActionableAlert(for: error.message)
            success = false
        }
        flushLogNow()
        return success
    }

    // MARK: - Download + convert

    func startDownload(
        outputDir: URL,
        conversionMode: ConversionMode,
        proResTier: ProResTier,
        h264Quality: H264Quality,
        downscale4K: Bool,
        deleteSourceAfterConversion: Bool = false,
        useHardwareAcceleration: Bool = true,
        preferMP4: Bool = false,
        cookiesFromBrowser: CookieBrowser = .none,
        sleepInterval: Bool = false
    ) {
        guard let videoID = selectedVideoID else { return }
        let audioID = useBestAudio ? nil : selectedAudioID
        let selector = audioID.map { "\(videoID)+\($0)" } ?? "\(videoID)+bestaudio"

        beginDownload(
            formatSelector: selector,
            outputDir: outputDir,
            conversionMode: conversionMode,
            proResTier: proResTier,
            h264Quality: h264Quality,
            downscale4K: downscale4K,
            deleteSourceAfterConversion: deleteSourceAfterConversion,
            useHardwareAcceleration: useHardwareAcceleration,
            preferMP4: preferMP4,
            cookiesFromBrowser: cookiesFromBrowser,
            sleepInterval: sleepInterval
        )
    }

    /// Basic mode's single entry point: hands a `BasicDownloadPlan` (built
    /// by `BasicModeService.plan` from the user's resolution + ProRes
    /// choice in the picker sheet) to the exact same engine Advanced mode
    /// uses. Not a second implementation — just a different way of
    /// arriving at `formatSelector`/`conversionMode`/`h264Quality`.
    func startBasicDownload(
        plan: BasicDownloadPlan,
        outputDir: URL,
        deleteSourceAfterConversion: Bool = false,
        useHardwareAcceleration: Bool = true,
        cookiesFromBrowser: CookieBrowser = .none,
        sleepInterval: Bool = false
    ) {
        beginDownload(
            formatSelector: plan.formatSelector,
            outputDir: outputDir,
            conversionMode: plan.conversionMode,
            proResTier: plan.proResTier,
            h264Quality: plan.h264Quality,
            downscale4K: false,
            deleteSourceAfterConversion: deleteSourceAfterConversion,
            useHardwareAcceleration: useHardwareAcceleration,
            preferMP4: false,
            cookiesFromBrowser: cookiesFromBrowser,
            sleepInterval: sleepInterval
        )
    }

    /// Entry point for the 403 alert's "Retry with Best-Quality Auto-Select"
    /// button — bypasses the current video/audio format selection entirely
    /// in favor of yt-dlp's own adaptive best-video+best-audio selector.
    /// Takes no parameters: reuses `lastRunConfig`, i.e. whatever
    /// conversion settings the failed attempt was actually started with
    /// (Advanced mode's Output-section state, or a Basic-mode plan's) —
    /// this matters because a fixed reference to Advanced's @AppStorage
    /// settings would silently ignore a Basic-mode run's ProRes/H.264
    /// choice on retry, breaking Basic mode's "always end up with a
    /// playable file" guarantee.
    func retryWithBestQualitySelector() {
        guard let config = lastRunConfig else { return }
        beginDownload(
            formatSelector: YTDLPService.fallbackFormatSelector,
            outputDir: config.outputDir,
            conversionMode: config.conversionMode,
            proResTier: config.proResTier,
            h264Quality: config.h264Quality,
            downscale4K: config.downscale4K,
            deleteSourceAfterConversion: config.deleteSourceAfterConversion,
            useHardwareAcceleration: config.useHardwareAcceleration,
            preferMP4: config.preferMP4,
            cookiesFromBrowser: config.cookiesFromBrowser,
            sleepInterval: config.sleepInterval
        )
    }

    /// Captures the settings a `beginDownload` call was actually started
    /// with, so `retryWithBestQualitySelector` (and any future no-context
    /// retry) can reuse them exactly rather than re-reading whatever the
    /// UI's current (possibly different, possibly Advanced-mode-only)
    /// state happens to be.
    private struct RunConfig {
        let outputDir: URL
        let conversionMode: ConversionMode
        let proResTier: ProResTier
        let h264Quality: H264Quality
        let downscale4K: Bool
        let deleteSourceAfterConversion: Bool
        let useHardwareAcceleration: Bool
        let preferMP4: Bool
        let cookiesFromBrowser: CookieBrowser
        let sleepInterval: Bool
    }
    private var lastRunConfig: RunConfig?

    private func beginDownload(
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
        sleepInterval: Bool
    ) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        let relevantNames: Set<String> = conversionMode != .none ? ["yt-dlp", "ffmpeg", "ffprobe"] : ["yt-dlp"]
        if let missing = Tool.missingTools().first(where: { relevantNames.contains($0.name) }) {
            missingToolAlert = missing
            return
        }

        lastRunConfig = RunConfig(
            outputDir: outputDir,
            conversionMode: conversionMode,
            proResTier: proResTier,
            h264Quality: h264Quality,
            downscale4K: downscale4K,
            deleteSourceAfterConversion: deleteSourceAfterConversion,
            useHardwareAcceleration: useHardwareAcceleration,
            preferMP4: preferMP4,
            cookiesFromBrowser: cookiesFromBrowser,
            sleepInterval: sleepInterval
        )

        isRunning = true
        lastError = nil
        actionableAlert = nil
        detectedColorInfo = nil
        lastOutputURL = nil
        progressFraction = nil
        progressETA = nil

        Task {
            await runDownloadAndConvert(
                url: trimmedURL,
                formatSelector: formatSelector,
                outputDir: outputDir,
                conversionMode: conversionMode,
                proResTier: proResTier,
                h264Quality: h264Quality,
                downscale4K: downscale4K,
                deleteSourceAfterConversion: deleteSourceAfterConversion,
                useHardwareAcceleration: useHardwareAcceleration,
                preferMP4: preferMP4,
                cookiesFromBrowser: cookiesFromBrowser,
                sleepInterval: sleepInterval
            )
            isRunning = false
            progressLabel = ""
            progressFraction = nil
            progressETA = nil
            flushLogNow()
        }
    }

    private func runDownloadAndConvert(
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
        sleepInterval: Bool
    ) async {
        // Tries the given format selector. Used for the initial attempt and
        // for the automatic 403 fallback retry (item 6) below — identical
        // flags either time, only -f differs.
        func attemptDownload(selector: String) async -> ProcessResult {
            let args = YTDLPService.downloadArguments(
                url: url, formatSelector: selector, outputDir: outputDir,
                preferMP4: preferMP4, cookiesFromBrowser: cookiesFromBrowser, sleepInterval: sleepInterval
            )
            progressLabel = "Downloading…"
            progressFraction = nil
            progressETA = nil
            appendLog("\n$ yt-dlp \(args.joined(separator: " "))\n")
            return await runner.run(
                path: Tool.ytdlp,
                arguments: args,
                qos: .userInitiated,
                onOutput: streamHandler(onChunk: { [weak self] chunk in
                    guard let progress = YTDLPService.parseDownloadProgress(from: chunk) else { return }
                    self?.progressFraction = progress.fraction
                    self?.progressETA = progress.eta
                })
            )
        }

        // Bounded retry loop (see maxAttemptsPerPhase): a genuinely transient
        // failure (HTTP 403) gets one automatic retry with a simpler format
        // selector. Anything SystemFailureKind recognizes as fatal (disk
        // full, permission denied, missing binary) never retries at all —
        // retrying those can only ever fail again, and previously nothing
        // stopped a caller from wiring up an unbounded loop around this.
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

            appendLog(
                "\nDownload failed with HTTP 403 — automatically retrying once with a simpler format "
                + "selection (\(YTDLPService.fallbackFormatSelector))…\n"
            )
            currentSelector = YTDLPService.fallbackFormatSelector
        } while true

        guard downloadResult.exitCode == 0 else {
            appendLog("\nyt-dlp exited with code \(downloadResult.exitCode).\n")
            switch SystemFailureKind.classify(downloadResult.output) {
            case .diskFull:
                lastError = "Not enough free space to complete the download."
                actionableAlert = ActionableAlert(
                    title: "Not Enough Disk Space",
                    message: diskFullMessage(at: outputDir, estimatedRequiredBytes: nil),
                    actionLabel: "OK",
                    action: nil
                )
            case .permissionDenied:
                lastError = "Download failed: permission denied writing to the output folder."
                actionableAlert = ActionableAlert(
                    title: "Permission Denied",
                    message: "Grab doesn't have permission to write to \(outputDir.path). Choose a "
                        + "different output folder, or grant access, then try again.",
                    actionLabel: "OK",
                    action: nil
                )
            case .missingBinary, .invalidInput, .none:
                lastError = "Download failed (see log)."
                presentActionableAlert(for: downloadResult.output)
            }
            return
        }

        guard let outputPath = YTDLPService.extractOutputFile(from: downloadResult.output) else {
            appendLog("\nDownload finished but the output file path could not be determined.\n")
            lastError = "Could not determine downloaded file path."
            return
        }
        appendLog("\nDownloaded: \(outputPath)\n")
        progressFraction = nil
        progressETA = nil

        let inputURL = URL(fileURLWithPath: outputPath)

        // Always inspect the source's color metadata (read-only, cheap) so
        // the "detected source" indicator has something to show even when
        // ProRes conversion itself is off this run.
        progressLabel = "Inspecting color metadata…"
        appendLog("\n$ ffprobe -show_entries stream=color_transfer,color_primaries \"\(inputURL.lastPathComponent)\"\n")

        let colorResult = await FFmpegService.probeColorInfo(fileURL: inputURL, runner: runner)
        let colorInfo: ColorInfo
        switch colorResult {
        case .success(let info):
            colorInfo = info
        case .failure(let error):
            appendLog("\nffprobe failed: \(error.message)\nDefaulting to SDR path.\n")
            colorInfo = ColorInfo(transfer: "unknown", primaries: "unknown")
        }
        appendLog("\nColor metadata: \(colorInfo.summary)\n")
        detectedColorInfo = colorInfo

        guard conversionMode != .none else {
            lastOutputURL = inputURL
            NotificationService.postCompletion(
                title: "Download Complete",
                body: "\(inputURL.lastPathComponent) is ready.",
                revealURL: inputURL
            )
            return
        }

        let isH264 = conversionMode == .h264
        let modeName = isH264 ? "H.264" : "ProRes"
        let outputURL = isH264
            ? FFmpegService.h264OutputURL(for: inputURL)
            : FFmpegService.proResOutputURL(for: inputURL)
        let usedHDRPath = colorInfo.isHDR

        appendLog(usedHDRPath
            ? "Detected HDR (PQ/BT.2020) — using HDR tone-map filter chain.\n"
            : "Detected SDR (bt709 / unspecified) — using direct SDR path.\n")
        if usedHDRPath && useHardwareAcceleration {
            appendLog("Note: the HDR tone-map filter chain (zscale/tonemap) runs on the CPU regardless of "
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
        // on the output volume, warning (with a Continue/Cancel choice)
        // before spending minutes encoding something that can't fit.
        // Best-effort like the duration probe above — if either probe
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
            let proceed = await confirmEnoughDiskSpace(requiredBytes: requiredBytes, at: outputURL.deletingLastPathComponent())
            guard proceed else {
                appendLog("\nConversion cancelled by user (not enough free space).\n")
                lastError = "Conversion cancelled (not enough free space)."
                return
            }
        }

        // Tries the hardware encoder (prores_videotoolbox / h264_videotoolbox)
        // or its software counterpart (prores_ks / libx264) depending on
        // `useHardware`. Filter chain is identical either way for both
        // modes; only the rate-control flags differ between H.264's
        // hardware (bitrate) and software (CRF) paths -- see
        // FFmpegService.h264ConversionArguments.
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

            progressFraction = nil
            progressETA = nil
            progressLabel = usedHDRPath
                ? "Converting to \(modeName) (\(encoderName), HDR tone-map)…"
                : "Converting to \(modeName) (\(encoderName))…"
            appendLog("\n$ ffmpeg \(args.joined(separator: " "))\n")

            let conversionStart = Date()
            return await runner.run(
                path: Tool.ffmpeg,
                arguments: args,
                qos: .userInitiated,
                onOutput: streamHandler(onChunk: { [weak self] chunk in
                    guard let self, let duration = sourceDuration,
                          let currentTime = FFmpegService.parseTimeSeconds(from: chunk) else { return }
                    let fraction = min(max(currentTime / duration, 0), 1)
                    self.progressFraction = fraction

                    let remaining = max(duration - currentTime, 0)
                    if let speed = FFmpegService.parseSpeed(from: chunk), speed > 0 {
                        self.progressETA = FFmpegService.formatDuration(remaining / speed)
                    } else if fraction > 0 {
                        let elapsed = Date().timeIntervalSince(conversionStart)
                        self.progressETA = FFmpegService.formatDuration(elapsed / fraction * (1 - fraction))
                    }
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
                appendLog("\nHardware encoder failed with a non-retryable error — not falling back to software encoding (see error below).\n")
            } else {
                let hardwareEncoder = isH264 ? FFmpegService.h264HardwareEncoder : FFmpegService.hardwareEncoder
                let softwareEncoder = isH264 ? FFmpegService.h264SoftwareEncoder : FFmpegService.softwareEncoder
                appendLog(
                    "\nHardware encoder (\(hardwareEncoder)) failed (exit code \(convertResult.exitCode))"
                    + " — falling back to software encoder (\(softwareEncoder)).\n"
                )
                conversionAttempts += 1
                convertResult = await attemptConversion(useHardware: false)
            }
        }

        if convertResult.exitCode == 0 {
            appendLog("\n\(modeName) conversion complete: \(outputURL.path)\n")

            if !isH264, case .success(let tag) = await FFmpegService.probeCodecTag(fileURL: outputURL, runner: runner) {
                appendLog("Output codec tag: \(tag) (expected apcn for 422, apch for 422 HQ)\n")
            }

            if deleteSourceAfterConversion {
                do {
                    try FileManager.default.removeItem(at: inputURL)
                    appendLog("Deleted source file: \(inputURL.path)\n")
                } catch {
                    appendLog("Could not delete source file: \(error.localizedDescription)\n")
                }
            }

            lastOutputURL = outputURL
            NotificationService.postCompletion(
                title: "\(modeName) Conversion Complete",
                body: "\(outputURL.lastPathComponent) is ready.",
                revealURL: outputURL
            )
        } else {
            appendLog("\nffmpeg exited with code \(convertResult.exitCode).\n")
            let outputDirectory = outputURL.deletingLastPathComponent()
            switch SystemFailureKind.classify(convertResult.output) {
            case .diskFull:
                lastError = "Not enough free space (see log)."
                actionableAlert = ActionableAlert(
                    title: "Not Enough Disk Space",
                    message: diskFullMessage(at: outputDirectory, estimatedRequiredBytes: estimatedRequiredBytes),
                    actionLabel: "OK",
                    action: nil
                )
            case .permissionDenied:
                lastError = "\(modeName) conversion failed: permission denied writing to the output folder."
                actionableAlert = ActionableAlert(
                    title: "Permission Denied",
                    message: "Grab doesn't have permission to write to \(outputDirectory.path). Choose a "
                        + "different output folder, or grant access, then try again.",
                    actionLabel: "OK",
                    action: nil
                )
            case .invalidInput:
                lastError = "\(modeName) conversion failed: the downloaded file appears invalid or corrupted."
                actionableAlert = ActionableAlert(
                    title: "Invalid Source File",
                    message: "ffmpeg couldn't read the downloaded file — it may be corrupted or incomplete. "
                        + "Try downloading again.",
                    actionLabel: "OK",
                    action: nil
                )
            case .missingBinary, .none:
                lastError = "\(modeName) conversion failed (see log)."
            }
        }
    }

    func cancel() {
        runner.cancel()
        appendLog("\n— Cancelled by user —\n")
    }
}
