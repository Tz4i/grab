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

    /// nil means "don't show" — either no update is available, the check
    /// hasn't completed yet, the check failed (handled silently, see
    /// YTDLPService.checkForUpdate), or the user dismissed the banner this
    /// session. Not persisted — a fresh launch re-checks and re-shows if
    /// still applicable, which is the point of an update nag. App-update
    /// checking (as opposed to yt-dlp) is no longer handled here at all —
    /// Sparkle owns that entirely now, see CLAUDE.md's "Auto-updates
    /// (Sparkle)" section; this file has nothing to do with it.
    @Published var ytdlpUpdateInfo: YTDLPUpdateInfo?
    @Published var isUpdatingYTDLPFromBanner = false

    /// Set when a pre-flight disk-space estimate comes up short, right
    /// before a conversion would start — the UI presents this as a
    /// Continue/Cancel alert and `resolveDiskSpaceWarning` resumes
    /// `diskSpaceContinuation` with the user's choice.
    @Published var diskSpaceWarning: DiskSpaceWarning?
    private var diskSpaceContinuation: CheckedContinuation<Bool, Never>?

    // MARK: - Playlist queue

    /// The playlist job queue — see AppViewModel+Queue.swift for all
    /// processing logic. A plain `@Published` array (not per-job
    /// `ObservableObject`s); mutated via id-based lookup throughout so
    /// concurrent remove/reorder/retry actions can't corrupt whichever job
    /// is currently processing.
    @Published var jobs: [Job] = []
    @Published var isProcessingQueue = false
    /// Distinct from `isProcessingQueue`: true only while the "which
    /// videos do you want?" checklist sheet is awaiting the flat-playlist
    /// enumeration, before any job exists yet.
    @Published var isEnumeratingPlaylist = false
    @Published var playlistEnumeration: (title: String?, entries: [PlaylistEntry])?
    @Published var playlistEnumerationError: String?

    /// A fully separate `ProcessRunner` instance from the single-video
    /// `runner` below — matches `ProcessRunner`'s own "one instance per
    /// operation, never a shared singleton" convention, so the queue's
    /// Cancel-current-job action can never affect (or be affected by) a
    /// concurrent single-video fetch/download. In practice the two never
    /// truly run at once (`isBusy` gates on both), but keeping them
    /// separate avoids any cross-cancellation surprise regardless.
    let queueRunner = ProcessRunner()
    var currentJobCancelRequested = false

    /// Full lockout while a queue runs — confirmed as the desired v1
    /// behavior (not a side effect of a one-line change): a queue can run
    /// for a while, and this keeps exactly one thing happening at a time
    /// in the app, matching the queue's own "never parallel downloads or
    /// encodes" requirement rather than introducing a second concurrent
    /// surface to reason about.
    var isBusy: Bool { isFetchingFormats || isRunning || isProcessingQueue || isEnumeratingPlaylist }

    private let runner = ProcessRunner()
    private var logBuffer = LogBuffer()
    private var logFlushPending = false

    init() {
        loadPersistedQueue()
    }

    /// Internal, not private: `DownloadProgressSink` conformance below
    /// uses it directly (same-file, would work either way), but the
    /// playlist queue's `JobSink` (a different file, AppViewModel+Queue.
    /// swift) also feeds the currently-processing job's yt-dlp/ffmpeg
    /// output into this same shared log — queue processing and
    /// single-video processing are mutually exclusive (`isBusy` gates
    /// both), so there's no interleaving risk, and it means "Show
    /// details" stays useful while a queue is running instead of going
    /// silent.
    func appendLog(_ text: String) {
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

    func flushLogNow() {
        logFlushPending = false
        log = logBuffer.text
    }

    /// Awaits the user's Continue/Cancel choice from a `DiskSpaceWarning`
    /// alert. `requiredBytes` is the pre-flight estimate; if the available
    /// space can't be determined at all, or is enough, this resolves
    /// `true` immediately with no prompt.
    func confirmEnoughDiskSpace(requiredBytes: Int64, at directory: URL) async -> Bool {
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

    /// Never awaited — callers (ContentView's launch `.task`) must not
    /// block on this. Silent-on-failure internally; nothing here needs its
    /// own error handling. This is yt-dlp's own version check only now —
    /// app-update checking used to fire alongside it here too, but that's
    /// entirely Sparkle's responsibility now (started independently from
    /// `GrabApp`, not triggered from this view model at all).
    func checkForUpdates() {
        Task {
            ytdlpUpdateInfo = await YTDLPService.checkForUpdate(runner: ProcessRunner())
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

    /// Thin wrapper around the shared `DownloadEngine` — reconstructs
    /// exactly the same `lastError`/`actionableAlert`/`lastOutputURL`/
    /// notification behavior the inline implementation used to have
    /// directly, just driven by the engine's `Outcome` instead. See
    /// `DownloadEngine.swift` for why the outcome shape preserves the
    /// asymmetry between download-failure and conversion-failure handling
    /// rather than collapsing to a flat error string.
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
        let outcome = await DownloadEngine.run(
            url: url,
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
            sleepInterval: sleepInterval,
            runner: runner,
            sink: self
        )

        switch outcome {
        case .success(let outputURL, let modeName):
            lastOutputURL = outputURL
            NotificationService.postCompletion(
                title: modeName.map { "\($0) Conversion Complete" } ?? "Download Complete",
                body: "\(outputURL.lastPathComponent) is ready.",
                revealURL: outputURL
            )
        case .downloadFailed(let rawOutput, let systemFailure):
            switch systemFailure {
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
                presentActionableAlert(for: rawOutput)
            }
        case .outputPathUndetermined:
            lastError = "Could not determine downloaded file path."
        case .diskSpaceDeclined:
            lastError = "Conversion cancelled (not enough free space)."
        case .conversionFailed(_, let systemFailure, let outputDirectory, let estimatedRequiredBytes, let modeName):
            switch systemFailure {
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

/// The single-video path's `DownloadEngine` reporting target — delegates
/// to the exact same private/internal methods and `@Published` properties
/// `runDownloadAndConvert` used to write to directly, so this extraction
/// changes nothing about single-video observable behavior. `setPhase` is
/// a no-op here: the single-video UI already conveys "downloading" vs
/// "converting" via `progressLabel`'s text, it doesn't need a separate
/// phase concept the way the queue's per-job `status` does.
extension AppViewModel: DownloadProgressSink {
    func setPhase(_ phase: DownloadEngine.Phase) {}

    func setProgressLabel(_ label: String) {
        progressLabel = label
    }

    func setProgressFraction(_ fraction: Double?) {
        progressFraction = fraction
    }

    func setProgressETA(_ eta: String?) {
        progressETA = eta
    }

    func setColorInfo(_ info: ColorInfo?) {
        detectedColorInfo = info
    }

    // confirmEnoughDiskSpace(requiredBytes:at:) is satisfied directly by
    // the existing method of the same signature above (had to be
    // `internal`, not `private`, to witness this protocol requirement —
    // Swift requires a witness to be at least as visible as the protocol
    // itself, same-file conformance doesn't relax that).
}
