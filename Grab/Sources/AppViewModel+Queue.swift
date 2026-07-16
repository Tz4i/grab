import Foundation

/// Everything related to the playlist job queue — kept out of
/// AppViewModel.swift itself (already substantial) to keep that file's
/// diff minimal and low-risk; this extension only adds new behavior, it
/// never touches the single-video path. See DownloadEngine.swift for the
/// shared engine both paths call, and Models.swift's `Job`/`JobStatus`
/// for the data shape.
extension AppViewModel {

    /// Snapshot of every setting relevant to a batch of queued jobs,
    /// captured once at "Add to Queue" time in the playlist selection
    /// sheet — mirrors `AppViewModel.RunConfig`'s single-video snapshot.
    struct QueueJobSettings {
        let outputDir: URL
        let isBasicMode: Bool
        let conversionMode: ConversionMode
        let h264Quality: H264Quality
        let proResTier: ProResTier
        let useProResForBasicMode: Bool
        let downscale4K: Bool
        let deleteSourceAfterConversion: Bool
        let useHardwareAcceleration: Bool
        let preferMP4: Bool
        let cookiesFromBrowser: CookieBrowser
        let sleepInterval: Bool
        let formatPolicy: PlaylistFormatPolicy
    }

    // MARK: - Playlist enumeration

    /// Wraps `YTDLPService.fetchPlaylistEntries` for the selection sheet —
    /// `isEnumeratingPlaylist` feeds into `isBusy`, so the rest of the app
    /// is locked out while this runs, same as any other fetch.
    @discardableResult
    func enumeratePlaylist(url: String, cookiesFromBrowser: CookieBrowser) async -> Bool {
        isEnumeratingPlaylist = true
        playlistEnumeration = nil
        playlistEnumerationError = nil

        let result = await YTDLPService.fetchPlaylistEntries(url: url, cookiesFromBrowser: cookiesFromBrowser, runner: queueRunner)
        isEnumeratingPlaylist = false

        switch result {
        case .success(let info):
            playlistEnumeration = info
            return true
        case .failure(let error):
            playlistEnumerationError = error.message
            return false
        }
    }

    // MARK: - Enqueue

    /// Builds one `Job` per selected entry and appends them to the queue.
    /// Checks `Tool.missingTools()` once, here — not per-job — so a
    /// missing binary surfaces as a single alert before anything starts,
    /// never mid-batch (a queue must never pop an interactive alert once
    /// it's running).
    func enqueue(entries: [PlaylistEntry], settings: QueueJobSettings) {
        guard !entries.isEmpty else { return }
        if let missing = Tool.missingTools().first {
            missingToolAlert = missing
            return
        }

        let newJobs = entries.map { entry in
            Job(
                id: UUID(),
                url: entry.url,
                title: entry.title,
                outputDir: settings.outputDir,
                isBasicMode: settings.isBasicMode,
                conversionMode: settings.conversionMode,
                h264Quality: settings.h264Quality,
                proResTier: settings.proResTier,
                useProResForBasicMode: settings.useProResForBasicMode,
                downscale4K: settings.downscale4K,
                deleteSourceAfterConversion: settings.deleteSourceAfterConversion,
                useHardwareAcceleration: settings.useHardwareAcceleration,
                preferMP4: settings.preferMP4,
                cookiesFromBrowser: settings.cookiesFromBrowser,
                sleepInterval: settings.sleepInterval,
                formatPolicy: settings.formatPolicy
            )
        }
        jobs.append(contentsOf: newJobs)
        persistQueue()
        processQueueIfNeeded()
    }

    // MARK: - Processing

    func processQueueIfNeeded() {
        guard !isProcessingQueue else { return }
        guard jobs.contains(where: { $0.status == .queued }) else { return }
        isProcessingQueue = true
        Task {
            await processQueue()
            isProcessingQueue = false
            flushLogNow()
        }
    }

    private func processQueue() async {
        var completedCount = 0
        var failedCount = 0

        while let job = jobs.first(where: { $0.status == .queued }) {
            await processJob(id: job.id)

            if let finished = jobs.first(where: { $0.id == job.id }) {
                switch finished.status {
                case .completed: completedCount += 1
                case .failed: failedCount += 1
                case .queued, .downloading, .converting, .cancelled: break
                }
            }

            // "Reduce request rate" applied between jobs, distinct from
            // yt-dlp's own per-download --sleep-interval flag (which still
            // applies too, inside DownloadEngine.run's downloadArguments).
            let moreQueued = jobs.contains(where: { $0.status == .queued })
            if job.sleepInterval && moreQueued {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        // One summary notification for the whole run — never one per job.
        // Deliberately counts only jobs finished in *this* processQueue
        // call, not the full `jobs` array (which could include older
        // completed/failed jobs left over from a previous run).
        guard completedCount + failedCount > 0 else { return }
        var parts: [String] = []
        if completedCount > 0 { parts.append("\(completedCount) completed") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        NotificationService.postCompletion(title: "Playlist Queue Finished", body: parts.joined(separator: ", "))
    }

    private func processJob(id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }

        updateJob(id) {
            $0.status = .downloading
            $0.progressLabel = "Fetching formats…"
        }
        // Persisted immediately (not just at completion/failure) so the
        // on-disk state actually reflects "this job was mid-flight" if
        // the app quits right here — otherwise the remap-on-load logic
        // below would never have anything to remap, since the file would
        // still say `.queued` from the last real write.
        persistQueue()
        appendLog("\n=== Queue: \(job.title) ===\n")

        let fetchResult = await YTDLPService.fetchFormats(
            url: job.url,
            cookiesFromBrowser: job.cookiesFromBrowser,
            runner: queueRunner,
            onOutput: { _ in }
        )

        let formats: [VideoFormat]
        switch fetchResult {
        case .success(let fetched):
            formats = fetched.formats
            updateJob(id) { $0.title = fetched.metadata.title }
        case .failure(let error):
            finishJob(id, failureMessage: "Could not fetch formats: \(error.message)")
            return
        }

        let formatSelector: String
        let resolvedConversionMode: ConversionMode
        let resolvedProResTier: ProResTier
        let resolvedH264Quality: H264Quality

        if job.isBasicMode {
            guard let plan = BasicModeService.planForPolicy(
                formats: formats, policy: job.formatPolicy,
                useProRes: job.useProResForBasicMode, proResTier: job.proResTier
            ) else {
                finishJob(id, failureMessage: "No suitable format was found for this video.")
                return
            }
            formatSelector = plan.formatSelector
            resolvedConversionMode = plan.conversionMode
            resolvedProResTier = plan.proResTier
            resolvedH264Quality = plan.h264Quality
        } else {
            guard let selector = PlaylistFormatSelector.advancedFormatSelector(formats: formats, policy: job.formatPolicy) else {
                finishJob(id, failureMessage: "No suitable format was found for this video.")
                return
            }
            formatSelector = selector
            resolvedConversionMode = job.conversionMode
            resolvedProResTier = job.proResTier
            resolvedH264Quality = job.h264Quality
        }

        let outcome = await DownloadEngine.run(
            url: job.url,
            formatSelector: formatSelector,
            outputDir: job.outputDir,
            conversionMode: resolvedConversionMode,
            proResTier: resolvedProResTier,
            h264Quality: resolvedH264Quality,
            downscale4K: job.downscale4K,
            deleteSourceAfterConversion: job.deleteSourceAfterConversion,
            useHardwareAcceleration: job.useHardwareAcceleration,
            preferMP4: job.preferMP4,
            cookiesFromBrowser: job.cookiesFromBrowser,
            sleepInterval: job.sleepInterval,
            runner: queueRunner,
            sink: JobSink(viewModel: self, jobID: id)
        )

        switch outcome {
        case .success(let outputURL, _):
            updateJob(id) {
                $0.status = .completed
                $0.outputURL = outputURL
                $0.progressLabel = ""
                $0.progressFraction = nil
                $0.progressETA = nil
            }
        case .downloadFailed(let rawOutput, _):
            finishJob(id, failureMessage: rawOutput.isEmpty ? "Download failed." : firstMeaningfulLine(rawOutput))
        case .outputPathUndetermined:
            finishJob(id, failureMessage: "Could not determine downloaded file path.")
        case .diskSpaceDeclined:
            finishJob(id, failureMessage: "Not enough free space.")
        case .conversionFailed(let rawOutput, _, _, _, let modeName):
            finishJob(id, failureMessage: "\(modeName) conversion failed: \(firstMeaningfulLine(rawOutput))")
        }
        persistQueue()
    }

    /// Marks a job Cancelled (if the user requested it) or Failed with the
    /// given message — the one place both outcomes converge, so
    /// `currentJobCancelRequested` only ever needs resetting here.
    private func finishJob(_ id: UUID, failureMessage: String) {
        let wasCancelled = currentJobCancelRequested
        currentJobCancelRequested = false
        updateJob(id) {
            $0.status = wasCancelled ? .cancelled : .failed
            $0.errorMessage = wasCancelled ? nil : failureMessage
            $0.progressLabel = ""
            $0.progressFraction = nil
            $0.progressETA = nil
        }
        persistQueue()
    }

    /// Raw process output can be long (full yt-dlp/ffmpeg stderr) — a
    /// job's `errorMessage` is shown inline in a compact queue row, so
    /// this trims it to the first non-blank line rather than dumping
    /// everything (the full output is still in the shared log via
    /// `appendLog`).
    private func firstMeaningfulLine(_ output: String) -> String {
        output.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? "Failed (see log)."
    }

    /// The single id-based mutation point for job state — both `JobSink`
    /// and `processJob` go through this, never a captured array index,
    /// since the array can be mutated concurrently by remove/reorder/
    /// clear actions while a job is mid-flight.
    fileprivate func updateJob(_ id: UUID, _ mutate: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    // MARK: - Queue actions

    /// Sets the cancel flag then terminates whatever `queueRunner` is
    /// currently running — the in-flight `DownloadEngine.run` call
    /// returns shortly after with a failure outcome, which `processJob`
    /// (via `finishJob`) turns into `.cancelled` rather than `.failed`
    /// because the flag is still set. The queue itself keeps going:
    /// `processQueue`'s loop just moves on to the next `.queued` job.
    func cancelCurrentQueueJob() {
        currentJobCancelRequested = true
        queueRunner.cancel()
    }

    /// Removing the actively-processing job is just a cancel — there's
    /// nothing else "remove" could safely mean while it's mid-flight.
    func removeJob(id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if job.status == .downloading || job.status == .converting {
            cancelCurrentQueueJob()
            return
        }
        jobs.removeAll { $0.id == id }
        persistQueue()
    }

    func retryJob(id: UUID) {
        updateJob(id) {
            $0.status = .queued
            $0.errorMessage = nil
            $0.progressFraction = nil
            $0.progressLabel = ""
            $0.progressETA = nil
            $0.outputURL = nil
        }
        persistQueue()
        processQueueIfNeeded()
    }

    /// Only `.completed` jobs — failed/cancelled ones stay visible so the
    /// user can still inspect/retry them.
    func clearCompletedJobs() {
        jobs.removeAll { $0.status == .completed }
        persistQueue()
    }

    func moveJobs(from source: IndexSet, to destination: Int) {
        jobs.move(fromOffsets: source, toOffset: destination)
        persistQueue()
    }

    // MARK: - Persistence (best-effort, per spec's "acceptable fallback" allowance)

    /// New territory for this app — everything else persists via
    /// `@AppStorage`/`UserDefaults`, but a `[Job]` array is a poor fit for
    /// that (arbitrary size, structured data), so this is a small JSON
    /// file in the app's Application Support directory instead. Any
    /// failure anywhere in this file (missing directory, encode/decode
    /// error, anything) falls back silently to an empty in-memory queue —
    /// never surfaced to the user, never crashes.
    private static var queueFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Grab", isDirectory: true).appendingPathComponent("queue.json")
    }

    /// Called after every *structural* queue change (add/remove/reorder/
    /// status transition) — never on the frequent per-tick
    /// `progressFraction`/`progressETA` writes `JobSink` makes during an
    /// active download/encode, which would otherwise hammer disk I/O many
    /// times a second. The actual write happens off the main thread.
    func persistQueue() {
        guard let url = Self.queueFileURL else { return }
        let snapshot = jobs
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Loaded once at launch (`AppViewModel.init`). Any job that was
    /// still `.downloading`/`.converting` when the app last quit gets
    /// remapped to `.queued` with its progress fields cleared — "mark
    /// interrupted jobs as needing retry, not complete," per spec.
    /// Deliberately does **not** start processing automatically; the user
    /// has to trigger that (add a job, or retry one), matching this app's
    /// existing pattern of never starting network/CPU work with no user
    /// action.
    func loadPersistedQueue() {
        guard let url = Self.queueFileURL,
              let data = try? Data(contentsOf: url),
              var loaded = try? JSONDecoder().decode([Job].self, from: data)
        else {
            return
        }
        for index in loaded.indices where loaded[index].status == .downloading || loaded[index].status == .converting {
            loaded[index].status = .queued
            loaded[index].progressFraction = nil
            loaded[index].progressLabel = ""
            loaded[index].progressETA = nil
        }
        jobs = loaded
    }
}

/// The playlist queue's `DownloadProgressSink` — writes into one specific
/// job's fields via `updateJob` instead of AppViewModel's own singular
/// `@Published` properties, so the queue never corrupts (or is corrupted
/// by) the single-video UI's state. Also mirrors output into the shared
/// log (see `AppViewModel.appendLog`'s doc comment) so "Show details"
/// stays useful while a queue is running. Disk-space confirmation always
/// auto-proceeds — a queue must never pop an interactive alert mid-batch;
/// a real out-of-space failure still surfaces as a normal failed outcome.
@MainActor
private final class JobSink: DownloadProgressSink {
    private weak var viewModel: AppViewModel?
    private let jobID: UUID

    init(viewModel: AppViewModel, jobID: UUID) {
        self.viewModel = viewModel
        self.jobID = jobID
    }

    func setPhase(_ phase: DownloadEngine.Phase) {
        viewModel?.updateJob(jobID) {
            $0.status = phase == .converting ? .converting : .downloading
        }
        // Same reasoning as processJob's initial persistQueue() call —
        // the on-disk state should reflect "converting" if the app quits
        // during the (often much longer) encode phase specifically.
        viewModel?.persistQueue()
    }

    func setProgressLabel(_ label: String) {
        viewModel?.updateJob(jobID) { $0.progressLabel = label }
    }

    func setProgressFraction(_ fraction: Double?) {
        viewModel?.updateJob(jobID) { $0.progressFraction = fraction }
    }

    func setProgressETA(_ eta: String?) {
        viewModel?.updateJob(jobID) { $0.progressETA = eta }
    }

    func appendLog(_ text: String) {
        viewModel?.appendLog(text)
    }

    func setColorInfo(_ info: ColorInfo?) {
        viewModel?.detectedColorInfo = info
    }

    func confirmEnoughDiskSpace(requiredBytes: Int64, at directory: URL) async -> Bool {
        viewModel?.appendLog(
            "\nEstimated output size may exceed free space on the output drive — proceeding anyway "
            + "(playlist queue jobs never prompt mid-batch; a real out-of-space failure will still mark "
            + "this job Failed and the queue will continue).\n"
        )
        return true
    }
}
