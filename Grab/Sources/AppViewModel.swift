import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var urlString: String = ""
    @Published var formats: [VideoFormat] = []
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

    var isBusy: Bool { isFetchingFormats || isRunning }

    private let runner = ProcessRunner()
    private let maxLogLength = 200_000

    private func appendLog(_ text: String) {
        log += text
        if log.count > maxLogLength {
            log = String(log.suffix(maxLogLength))
        }
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
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        if let missing = Tool.missingTools().first(where: { $0.name == "yt-dlp" }) {
            missingToolAlert = missing
            return
        }

        formats = []
        selectedVideoID = nil
        selectedAudioID = nil
        lastError = nil
        actionableAlert = nil
        detectedColorInfo = nil
        progressFraction = nil
        progressETA = nil
        isFetchingFormats = true
        progressLabel = "Fetching formats…"
        appendLog("$ yt-dlp -F --no-warnings \"\(trimmedURL)\"\n")

        Task {
            let result = await YTDLPService.fetchFormats(
                url: trimmedURL,
                cookiesFromBrowser: cookiesFromBrowser,
                runner: runner,
                onOutput: streamHandler()
            )
            isFetchingFormats = false
            progressLabel = ""

            switch result {
            case .success(let fetched):
                formats = fetched
                selectedVideoID = fetched.first(where: { !$0.isAudioOnly })?.id
                selectedAudioID = fetched.first(where: { $0.isAudioOnly })?.id
                appendLog("\nFound \(fetched.count) format(s).\n")
            case .failure(let error):
                appendLog("\nyt-dlp failed:\n\(error.message)\n")
                lastError = error.message
                presentActionableAlert(for: error.message)
            }
        }
    }

    // MARK: - Download + convert

    func startDownload(
        outputDir: URL,
        convertToProRes: Bool,
        tier: ProResTier,
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
            convertToProRes: convertToProRes,
            tier: tier,
            downscale4K: downscale4K,
            deleteSourceAfterConversion: deleteSourceAfterConversion,
            useHardwareAcceleration: useHardwareAcceleration,
            preferMP4: preferMP4,
            cookiesFromBrowser: cookiesFromBrowser,
            sleepInterval: sleepInterval
        )
    }

    /// Entry point for the 403 alert's "Retry with Best-Quality Auto-Select"
    /// button — bypasses the current video/audio format selection entirely
    /// in favor of yt-dlp's own adaptive best-video+best-audio selector.
    func retryWithBestQualitySelector(
        outputDir: URL,
        convertToProRes: Bool,
        tier: ProResTier,
        downscale4K: Bool,
        deleteSourceAfterConversion: Bool,
        useHardwareAcceleration: Bool,
        preferMP4: Bool,
        cookiesFromBrowser: CookieBrowser,
        sleepInterval: Bool
    ) {
        beginDownload(
            formatSelector: YTDLPService.fallbackFormatSelector,
            outputDir: outputDir,
            convertToProRes: convertToProRes,
            tier: tier,
            downscale4K: downscale4K,
            deleteSourceAfterConversion: deleteSourceAfterConversion,
            useHardwareAcceleration: useHardwareAcceleration,
            preferMP4: preferMP4,
            cookiesFromBrowser: cookiesFromBrowser,
            sleepInterval: sleepInterval
        )
    }

    private func beginDownload(
        formatSelector: String,
        outputDir: URL,
        convertToProRes: Bool,
        tier: ProResTier,
        downscale4K: Bool,
        deleteSourceAfterConversion: Bool,
        useHardwareAcceleration: Bool,
        preferMP4: Bool,
        cookiesFromBrowser: CookieBrowser,
        sleepInterval: Bool
    ) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        let relevantNames: Set<String> = convertToProRes ? ["yt-dlp", "ffmpeg", "ffprobe"] : ["yt-dlp"]
        if let missing = Tool.missingTools().first(where: { relevantNames.contains($0.name) }) {
            missingToolAlert = missing
            return
        }

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
                convertToProRes: convertToProRes,
                tier: tier,
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
        }
    }

    private func runDownloadAndConvert(
        url: String,
        formatSelector: String,
        outputDir: URL,
        convertToProRes: Bool,
        tier: ProResTier,
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

        var downloadResult = await attemptDownload(selector: formatSelector)

        if downloadResult.exitCode != 0,
           formatSelector != YTDLPService.fallbackFormatSelector,
           YTDLPService.classifyFailure(downloadResult.output) == .forbidden403 {
            appendLog(
                "\nDownload failed with HTTP 403 — automatically retrying once with a simpler format "
                + "selection (\(YTDLPService.fallbackFormatSelector))…\n"
            )
            downloadResult = await attemptDownload(selector: YTDLPService.fallbackFormatSelector)
        }

        guard downloadResult.exitCode == 0 else {
            appendLog("\nyt-dlp exited with code \(downloadResult.exitCode).\n")
            lastError = "Download failed (see log)."
            presentActionableAlert(for: downloadResult.output)
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

        guard convertToProRes else {
            lastOutputURL = inputURL
            NotificationService.postCompletion(
                title: "Download Complete",
                body: "\(inputURL.lastPathComponent) is ready.",
                revealURL: inputURL
            )
            return
        }

        let outputURL = FFmpegService.proResOutputURL(for: inputURL)
        let usedHDRPath = colorInfo.isHDR

        appendLog(usedHDRPath
            ? "Detected HDR (PQ/BT.2020) — using HDR tone-map filter chain.\n"
            : "Detected SDR (bt709 / unspecified) — using direct SDR path.\n")
        if usedHDRPath && useHardwareAcceleration {
            appendLog("Note: the HDR tone-map filter chain (zscale/tonemap) runs on the CPU regardless of "
                + "hardware acceleration — only the final ProRes encode step uses the hardware encoder.\n")
        }

        // Best-effort duration probe purely for the progress bar; a failure
        // here just means an indeterminate progress bar, nothing else. Uses
        // the same shared `runner` as everything else so Cancel still works
        // correctly if it lands while this quick probe is in flight.
        var sourceDuration: TimeInterval?
        if case .success(let duration) = await FFmpegService.probeDuration(fileURL: inputURL, runner: runner) {
            sourceDuration = duration
        }

        // Tries prores_videotoolbox or prores_ks depending on `useHardware`.
        // Filter chain / tier are identical either way — only -c:v differs,
        // since both encoders use the same -profile:v numbering (0...4).
        func attemptConversion(useHardware: Bool) async -> ProcessResult {
            let (args, _) = FFmpegService.conversionArguments(
                inputURL: inputURL, outputURL: outputURL, colorInfo: colorInfo,
                tier: tier, downscale4K: downscale4K, useHardwareEncoder: useHardware
            )
            let encoderName = useHardware ? FFmpegService.hardwareEncoder : FFmpegService.softwareEncoder

            progressFraction = nil
            progressETA = nil
            progressLabel = usedHDRPath
                ? "Converting to ProRes (\(encoderName), HDR tone-map)…"
                : "Converting to ProRes (\(encoderName))…"
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

        var convertResult = await attemptConversion(useHardware: useHardwareAcceleration)

        if useHardwareAcceleration && convertResult.exitCode != 0 {
            appendLog(
                "\nHardware encoder (\(FFmpegService.hardwareEncoder)) failed (exit code \(convertResult.exitCode))"
                + " — falling back to software encoder (\(FFmpegService.softwareEncoder)).\n"
            )
            convertResult = await attemptConversion(useHardware: false)
        }

        if convertResult.exitCode == 0 {
            appendLog("\nProRes conversion complete: \(outputURL.path)\n")

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
                title: "ProRes Conversion Complete",
                body: "\(outputURL.lastPathComponent) is ready.",
                revealURL: outputURL
            )
        } else {
            appendLog("\nffmpeg exited with code \(convertResult.exitCode).\n")
            lastError = "ProRes conversion failed (see log)."
        }
    }

    func cancel() {
        runner.cancel()
        appendLog("\n— Cancelled by user —\n")
    }
}
