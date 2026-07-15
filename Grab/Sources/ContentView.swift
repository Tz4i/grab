import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var dependencySetup = DependencySetupViewModel()
    @Environment(\.openSettings) private var openSettings

    @AppStorage("outputDirectoryPath") private var outputDirectoryPath: String =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasAcknowledgedDisclaimer") private var hasAcknowledgedDisclaimer = false
    /// Fire-once cross-scene signal: Settings' Debug section sets this to
    /// true to force the setup sheet open for testing; ContentView catches
    /// the flip via .onChange and immediately resets it back to false. Same
    /// pattern this codebase already uses for `cookiesFromBrowser`/
    /// `showLogPanel` — a shared @AppStorage key declared independently in
    /// both scenes, since there's no @EnvironmentObject bridging them.
    @AppStorage("debugForceShowSetupScreen") private var debugForceShowSetupScreen = false

    @State private var showSetupSheet = false

    /// Basic vs Advanced UI mode — see CLAUDE.md's "Basic / Advanced
    /// mode" section. Defaults to Basic.
    @AppStorage("appMode") private var appMode: AppMode = .basic
    /// Basic mode's single "Editing quality (ProRes)" toggle, shown in the
    /// resolution-picker sheet — persists across launches like every other
    /// conversion-related setting in this file.
    @AppStorage("basicUseProRes") private var basicUseProRes = false
    /// Basic mode's ProRes tier, only shown/relevant once the toggle above
    /// is on. Defaults to 422 (`ProResTier.basicModeDefault`), deliberately
    /// *not* 422 HQ like Advanced mode's `proResTier` default below — 422
    /// is the honest "good balance" recommendation for Basic mode's
    /// audience.
    @AppStorage("basicProResTier") private var basicProResTier: ProResTier = ProResTier.basicModeDefault
    /// Basic mode's "delete source file after conversion" toggle — default
    /// on, since ProRes files are large and keeping both the download and
    /// the converted file wastes significant disk space. Still a real,
    /// visible, persisted toggle, not forced behavior.
    @AppStorage("basicDeleteSourceAfterConversion") private var basicDeleteSourceAfterConversion = true
    @State private var showBasicResolutionSheet = false

    @AppStorage("conversionMode") private var conversionMode: ConversionMode = .none
    @AppStorage("proResTier") private var proResTier: ProResTier = .standard
    @AppStorage("h264Quality") private var h264Quality: H264Quality = .medium
    @AppStorage("downscale4K") private var downscale4K = false
    @AppStorage("deleteSourceAfterConversion") private var deleteSourceAfterConversion = false
    @AppStorage("useHardwareAcceleration") private var useHardwareAcceleration = true
    @AppStorage("hideBelow720p") private var hideBelow720p = false
    @AppStorage("logExpanded") private var logExpanded = false
    @AppStorage("showLogPanel") private var showLogPanel = true
    @AppStorage("preferMP4") private var preferMP4 = false
    @AppStorage("sleepInterval") private var sleepInterval = false
    @AppStorage("cookiesFromBrowser") private var cookiesFromBrowser: CookieBrowser = .none

    @State private var sortOrder: [KeyPathComparator<VideoFormat>] = [KeyPathComparator(\.resolutionPixels, order: .reverse)]

    private var outputDirectoryURL: URL { URL(fileURLWithPath: outputDirectoryPath) }

    private var displayedFormats: [VideoFormat] {
        let base = hideBelow720p
            ? viewModel.formats.filter { $0.isAudioOnly || ($0.resolutionHeight ?? 0) >= 720 }
            : viewModel.formats
        return base.sorted(using: sortOrder)
    }

    /// The hosting NSWindow, captured via `WindowAccessor` below — needed
    /// to actively resize the window's height per mode. SwiftUI's
    /// `.frame(minHeight:)` only constrains how small/large a *manual*
    /// resize can go; it does not itself shrink or grow the window's
    /// current frame when that constraint changes (e.g. switching from
    /// Advanced to Basic), which is exactly why Basic mode used to inherit
    /// whatever height Advanced mode (or the saved/default frame) last
    /// had. `applyWindowHeight` below is what actually moves the frame.
    @State private var hostWindow: NSWindow?

    /// Basic mode's content (URL field is in the toolbar, not here; just
    /// the color badge + output folder + status/progress + version
    /// footer) is much shorter than Advanced's formats table + full
    /// conversion controls — these are each mode's *default* height, not
    /// a remembered per-mode size; switching modes always snaps to the
    /// new mode's default (per spec — manual resizing afterward is still
    /// allowed, just not persisted across a mode switch).
    /// Advanced mode's default is a fixed, historically-tuned height (its
    /// content — formats table + full conversion controls — easily
    /// exceeds any natural minimum, so hardcoding is fine). Bumped from
    /// the original 780 to 1160 when the visual-polish pass wrapped each
    /// section in a padded/headered `SectionCard` — re-measured empirically
    /// (temporarily forcing a tall window and screenshotting) so the
    /// Conversion section and the log disclosure/version footer stay on
    /// screen instead of being clipped by a now-too-short fixed height.
    /// Basic mode instead uses
    /// `hostWindow.minSize.height` — the natural minimum height SwiftUI's
    /// `.windowResizability(.automatic)` already computed from Basic
    /// mode's actual rendered content — rather than a second hardcoded
    /// guess. This matters because native controls (`Form`, etc.) have
    /// their own intrinsic minimum row heights that a `.frame(minHeight:)`
    /// hint can't force them below; a hardcoded target smaller than that
    /// true minimum gets silently clamped back up by `NSWindow.setFrame`
    /// (verified: requesting 320 when the real minimum was 352 just
    /// produced 352, not 320) — asking the window for its own already-
    /// computed minimum sidesteps needing to guess a number that matches
    /// the real content at all.
    private func defaultWindowHeight(for mode: AppMode, window: NSWindow) -> CGFloat {
        mode == .advanced ? 1160 : window.minSize.height
    }

    /// Resizes the hosting window to the given mode's default height,
    /// keeping the window's width, x-origin, and *top* edge fixed (so it
    /// visually shrinks/grows from the bottom, anchored where the user's
    /// eye already is — the title bar/toolbar don't jump). Deferred one
    /// runloop tick so SwiftUI's own window-constraint update (driven by
    /// the `.frame(minHeight:)` that changed along with `mode`) has
    /// already landed on `window.minSize` before Basic mode reads it.
    private func applyWindowHeight(for mode: AppMode, animate: Bool) {
        guard let hostWindow else { return }
        DispatchQueue.main.async {
            let targetHeight = defaultWindowHeight(for: mode, window: hostWindow)
            var frame = hostWindow.frame
            guard abs(frame.height - targetHeight) > 0.5 else { return }
            let top = frame.origin.y + frame.height
            frame.size.height = targetHeight
            frame.origin.y = top - targetHeight
            hostWindow.setFrame(frame, display: true, animate: animate)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            updateBannersSection
            videoInfoSection
            if appMode == .advanced {
                formatsSection
                colorIndicatorBadge
                downloadOptionsSection
                outputFolderSection
                conversionSection
            } else {
                colorIndicatorBadge
                outputFolderSection
            }
            statusSection
            versionFooter
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: appMode == .advanced ? 620 : 300, alignment: .top)
        // Solid, neutral, opaque — NOT a material. A material here (the
        // previous `.background(.regularMaterial)`) sat behind the *entire*
        // content VStack, not just window chrome, so every card/table/form
        // sample-blended with whatever was behind the window (wallpaper,
        // other app windows) and picked up its color — a warm wallpaper
        // gave the whole app a warm cast, confirmed by pixel-sampling real
        // screenshots. `.windowBackgroundColor` is the standard native
        // "opaque window content background" color and does not vibrate/
        // sample a backdrop the way `Material` does. The toolbar/title bar
        // above this content view keeps its own native translucent
        // vibrancy automatically (from `.toolbar` being present at all —
        // see "Window chrome translucency" in CLAUDE.md) — that's a
        // separate AppKit-drawn region from this VStack's background, so
        // removing the material here doesn't affect it.
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            WindowAccessor { window in
                guard hostWindow !== window else { return }
                hostWindow = window
                applyWindowHeight(for: appMode, animate: false)
            }
        )
        .onChange(of: appMode) { _, newMode in
            applyWindowHeight(for: newMode, animate: true)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showBasicResolutionSheet) {
            BasicResolutionSheet(
                title: viewModel.videoMetadata?.title,
                choices: BasicModeService.availableResolutionChoices(formats: viewModel.formats),
                useProRes: $basicUseProRes,
                proResTier: $basicProResTier,
                deleteSourceAfterConversion: $basicDeleteSourceAfterConversion,
                onGo: { choice in
                    showBasicResolutionSheet = false
                    guard let plan = BasicModeService.plan(
                        for: choice, formats: viewModel.formats, useProRes: basicUseProRes, proResTier: basicProResTier
                    ) else {
                        return
                    }
                    viewModel.startBasicDownload(
                        plan: plan,
                        outputDir: outputDirectoryURL,
                        // Only meaningful when ProRes was actually chosen —
                        // never let a persisted "on" value leak into the
                        // (non-ProRes) H.264 direct-download/auto-convert
                        // paths, which the toggle isn't shown for.
                        deleteSourceAfterConversion: basicUseProRes ? basicDeleteSourceAfterConversion : false,
                        useHardwareAcceleration: useHardwareAcceleration,
                        cookiesFromBrowser: cookiesFromBrowser,
                        sleepInterval: sleepInterval
                    )
                },
                onCancel: { showBasicResolutionSheet = false }
            )
        }
        .task {
            NotificationService.requestAuthorizationIfNeeded()
            viewModel.checkYTDLPVersion()
            viewModel.checkForUpdates()
            await dependencySetup.refresh()
            if !hasCompletedOnboarding || !dependencySetup.missingRequired.isEmpty {
                showSetupSheet = true
            }
        }
        .onChange(of: debugForceShowSetupScreen) { _, forced in
            guard forced else { return }
            showSetupSheet = true
            debugForceShowSetupScreen = false
        }
        .sheet(isPresented: $showSetupSheet) {
            DependencySetupView(
                viewModel: dependencySetup,
                hasAcknowledgedDisclaimer: $hasAcknowledgedDisclaimer,
                onContinue: {
                    hasCompletedOnboarding = true
                    showSetupSheet = false
                }
            )
        }
        .alert(
            "Missing tool",
            isPresented: Binding(
                get: { viewModel.missingToolAlert != nil },
                set: { if !$0 { viewModel.missingToolAlert = nil } }
            ),
            presenting: viewModel.missingToolAlert
        ) { _ in
            Button("OK", role: .cancel) { viewModel.missingToolAlert = nil }
        } message: { missing in
            Text("Grab expected \(missing.name) at \(missing.path) but it isn't there.\n\nInstall it with:\n\nbrew install \(missing.name)")
        }
        .alert(
            viewModel.actionableAlert?.title ?? "",
            isPresented: Binding(
                get: { viewModel.actionableAlert != nil },
                set: { if !$0 { viewModel.actionableAlert = nil } }
            ),
            presenting: viewModel.actionableAlert
        ) { alert in
            if let action = alert.action {
                Button(alert.actionLabel) {
                    switch action {
                    case .openSettings:
                        openSettings()
                    case .retryBestQuality:
                        viewModel.retryWithBestQualitySelector()
                    }
                    viewModel.actionableAlert = nil
                }
                Button("Cancel", role: .cancel) { viewModel.actionableAlert = nil }
            } else {
                Button("OK", role: .cancel) { viewModel.actionableAlert = nil }
            }
        } message: { alert in
            Text(alert.message)
        }
        .alert(
            "Low Disk Space",
            isPresented: Binding(
                get: { viewModel.diskSpaceWarning != nil },
                set: { if !$0 { viewModel.resolveDiskSpaceWarning(proceed: false) } }
            ),
            presenting: viewModel.diskSpaceWarning
        ) { _ in
            Button("Continue Anyway", role: .destructive) { viewModel.resolveDiskSpaceWarning(proceed: true) }
            Button("Cancel", role: .cancel) { viewModel.resolveDiskSpaceWarning(proceed: false) }
        } message: { warning in
            Text(warning.message)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Mode", selection: $appMode) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .disabled(viewModel.isBusy)
            .help("Basic: paste a URL and pick a resolution. Advanced: full format table and conversion controls.")
        }

        ToolbarItem(placement: .principal) {
            TextField("YouTube URL", text: $viewModel.urlString)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260, idealWidth: 420)
                .disabled(viewModel.isBusy)
                .onSubmit { handleURLFieldSubmit() }
        }

        if appMode == .advanced {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.fetchFormats(cookiesFromBrowser: cookiesFromBrowser)
                } label: {
                    Label("Fetch Formats", systemImage: "list.bullet.rectangle.portrait")
                }
                .disabled(viewModel.isBusy || viewModel.urlString.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Fetch available formats for this URL")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.selectBestQuality()
                } label: {
                    Label("Best Quality", systemImage: "sparkles")
                }
                .disabled(viewModel.formats.isEmpty || viewModel.isBusy)
                .help("Select the highest-resolution video and best audio automatically")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            if viewModel.isBusy {
                Button(role: .destructive) {
                    viewModel.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .help("Cancel the running operation")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            if appMode == .advanced {
                Button {
                    viewModel.startDownload(
                        outputDir: outputDirectoryURL,
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
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isBusy || viewModel.selectedVideoID == nil)
                .help("Download the selected formats")
            } else {
                Button {
                    startBasicFlow()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isBusy || viewModel.urlString.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Fetch formats and choose a resolution")
            }
        }
    }

    // MARK: - Update banners

    /// yt-dlp's own update nag only now — the app-update banner that used
    /// to live here (GitHub-API-polling `AppUpdateService`, just linking to
    /// the release page) is gone; Sparkle owns app-update checking/UI
    /// entirely now, via the "Check for Updates…" app-menu item and its
    /// own automatic background check — see CLAUDE.md's "Auto-updates
    /// (Sparkle)" section.
    @ViewBuilder
    private var updateBannersSection: some View {
        if let info = viewModel.ytdlpUpdateInfo {
            updateBanner(
                icon: "arrow.triangle.2.circlepath",
                text: "A newer yt-dlp is available (installed \(info.installed) → latest \(info.latest)). "
                    + "Update now?",
                actionLabel: "Update",
                isBusy: viewModel.isUpdatingYTDLPFromBanner,
                action: { Task { await viewModel.updateYTDLPFromBanner() } },
                dismiss: { viewModel.ytdlpUpdateInfo = nil }
            )
        }
    }

    private func updateBanner(
        icon: String,
        text: String,
        actionLabel: String,
        isBusy: Bool,
        action: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(actionLabel, action: action)
                    .controlSize(.small)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Video info (title / thumbnail / duration / channel)

    /// Confirms the right video was found before (and during) download —
    /// shown in both modes. Basic mode renders it prominently (it's the
    /// main thing filling that mode's otherwise-thin window before a
    /// download starts); Advanced mode renders a smaller version above the
    /// Formats table. Stays visible through download/conversion too, since
    /// `AppViewModel.videoMetadata` is only cleared at the start of the
    /// next fetch, not by `beginDownload`.
    @ViewBuilder
    private var videoInfoSection: some View {
        if viewModel.isFetchingFormats {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Fetching video info…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let metadata = viewModel.videoMetadata {
            videoInfoCard(metadata: metadata, prominent: appMode == .basic)
        }
    }

    private func videoInfoCard(metadata: VideoMetadata, prominent: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            videoThumbnail(url: metadata.thumbnailURL)
                .frame(width: prominent ? 176 : 96, height: prominent ? 99 : 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(metadata.title)
                    .font(prominent ? .title3.weight(.semibold) : .headline)
                    .lineLimit(prominent ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let channel = metadata.channel {
                        Label(channel, systemImage: "person.circle")
                    }
                    Label(metadata.displayDuration, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(prominent ? 14 : 8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func videoThumbnail(url: URL?) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        ProgressView().controlSize(.small)
                    case .failure:
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
        .clipped()
    }

    // MARK: - Formats

    private var formatsSection: some View {
        SectionCard(title: "Formats", systemImage: "film") {
            formatsContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !viewModel.formats.isEmpty {
                Divider()
                HStack {
                    Toggle("Use best audio automatically", isOn: $viewModel.useBestAudio)
                    Toggle("Hide below 720p", isOn: $hideBelow720p)
                    Spacer()
                    Text(selectionSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var formatsContent: some View {
        if viewModel.isFetchingFormats {
            VStack(spacing: 8) {
                ProgressView()
                Text("Fetching formats…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.formats.isEmpty {
            ContentUnavailableView(
                "No Formats Yet",
                systemImage: "list.bullet.rectangle.portrait",
                description: Text("Enter a YouTube URL in the toolbar and click Fetch Formats.")
            )
        } else {
            formatsTable
        }
    }

    private var formatsTable: some View {
        Table(displayedFormats, sortOrder: $sortOrder) {
            TableColumn("ID", value: \.id) { format in
                Text(format.id)
            }
            .width(min: 40, ideal: 50, max: 70)

            TableColumn("Ext", value: \.ext) { format in
                Text(format.ext)
            }
            .width(min: 36, ideal: 48, max: 64)

            TableColumn("Resolution", value: \.resolutionPixels) { format in
                Text(format.displayResolution)
            }
            .width(min: 80, ideal: 100, max: 140)

            TableColumn("FPS", value: \.displayFPS) { format in
                Text(format.displayFPS)
            }
            .width(min: 32, ideal: 40, max: 56)

            TableColumn("Codec", value: \.displayCodec) { format in
                Text(format.displayCodec)
            }
            .width(min: 90, ideal: 140, max: 220)

            TableColumn("Size", value: \.displayFilesize) { format in
                Text(format.displayFilesize)
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn("Use") { format in
                formatSelectButtons(for: format)
            }
            .width(min: 60, ideal: 64, max: 64)
        }
        .frame(minHeight: 200, maxHeight: 520)
    }

    private func formatSelectButtons(for format: VideoFormat) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.selectedVideoID = format.id
            } label: {
                Image(systemName: viewModel.selectedVideoID == format.id ? "video.fill" : "video")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(viewModel.selectedVideoID == format.id ? Color.accentColor : Color.secondary)
            .disabled(format.isAudioOnly)
            .opacity(format.isAudioOnly ? 0.25 : 1)
            .help("Use as video source")

            Button {
                viewModel.selectedAudioID = format.id
            } label: {
                Image(systemName: viewModel.selectedAudioID == format.id ? "waveform.circle.fill" : "waveform.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(viewModel.selectedAudioID == format.id ? Color.accentColor : Color.secondary)
            .disabled(!format.isAudioOnly || viewModel.useBestAudio)
            .opacity(format.isAudioOnly ? 1 : 0.25)
            .help("Use as audio source")
        }
    }

    private var selectionSummaryText: String {
        let video = viewModel.selectedVideoID ?? "none"
        let audio = viewModel.useBestAudio ? "best (auto)" : (viewModel.selectedAudioID ?? "none")
        return "Video: \(video)   ·   Audio: \(audio)"
    }

    // MARK: - Source color indicator

    private var colorIndicatorBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: colorIndicatorIcon)
            Text(colorIndicatorText)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(colorIndicatorTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    private var colorIndicatorIcon: String {
        guard let info = viewModel.detectedColorInfo else { return "questionmark.circle" }
        return info.isHDR ? "sparkles" : "tv"
    }

    private var colorIndicatorTint: Color {
        guard let info = viewModel.detectedColorInfo else { return .secondary }
        return info.isHDR ? .purple : .green
    }

    private var colorIndicatorText: String {
        guard let info = viewModel.detectedColorInfo else { return "Source color: not yet checked" }
        if info.isHDR {
            return "HDR (\(info.primaries)/PQ) — will tone-map to SDR"
        }
        return "SDR (\(info.transfer))"
    }

    // MARK: - Download options

    private var downloadOptionsSection: some View {
        SectionCard(title: "Download", systemImage: "arrow.down.circle") {
            Form {
                Section {
                    Toggle("Prefer MP4 container", isOn: $preferMP4)
                    if preferMP4 {
                        Text("Prefers mp4 video / m4a audio at the same resolution. If a resolution is only "
                            + "available as webm (common at 8K), it will still download webm rather than "
                            + "dropping resolution.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Reduce request rate", isOn: $sleepInterval)
                        .help("Sleeps a few seconds before each download. Can help reduce bot-detection triggers.")
                }
            }
            .formStyle(.grouped)
            // `Form(.grouped)`'s own Section box renders with a vibrant
            // internal background on this system (confirmed by an isolated
            // test harness: real desktop/backdrop color visibly bled through
            // the grouped Section's row area even though this Form sits on
            // an already-opaque SectionCard). `.scrollContentBackground(.hidden)`
            // turns that off so the rows show the plain opaque SectionCard
            // background behind them instead — verified neutral via pixel
            // sampling with a saturated magenta/cyan backdrop directly behind
            // the window.
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(viewModel.isBusy)
        }
    }

    // MARK: - Output section

    /// Just the output-folder picker — shared by both modes (see CLAUDE.md's
    /// "Shared behavior": output folder setting is identical in both).
    /// Split out from the conversion controls below, which are Advanced-only.
    private var outputFolderSection: some View {
        SectionCard(title: "Output", systemImage: "folder") {
            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(outputDirectoryPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseOutputDirectory() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(viewModel.isBusy)
        }
    }

    private var conversionSection: some View {
        SectionCard(title: "Conversion", systemImage: "wand.and.stars") {
            Form {
                Section {
                    Picker("Convert to", selection: $conversionMode) {
                        ForEach(ConversionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    if let description = conversionMode.tradeoffDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    switch conversionMode {
                    case .none:
                        EmptyView()
                    case .proRes:
                        Picker("Tier", selection: $proResTier) {
                            ForEach(ProResTier.allCases) { tier in
                                Text(tier.label).tag(tier)
                            }
                        }
                    case .h264:
                        Picker("Quality", selection: $h264Quality) {
                            ForEach(H264Quality.allCases) { quality in
                                Text(quality.label).tag(quality)
                            }
                        }
                    }

                    if conversionMode != .none {
                        Toggle("Downscale to 4K (3840×2160)", isOn: $downscale4K)
                        Toggle("Delete source file after conversion", isOn: $deleteSourceAfterConversion)
                        Toggle("Use hardware acceleration", isOn: $useHardwareAcceleration)
                            .help(hardwareAccelerationHelpText)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(viewModel.isBusy)
        }
    }

    private var hardwareAccelerationHelpText: String {
        switch conversionMode {
        case .h264:
            return "Uses the Mac's hardware H.264 encoder (h264_videotoolbox) when available, automatically "
                + "falling back to software encoding (libx264) if it fails."
        case .proRes, .none:
            return "Uses the Mac's hardware ProRes encoder (prores_videotoolbox) when available, automatically "
                + "falling back to software encoding (prores_ks) if it fails."
        }
    }

    // MARK: - Status / progress / log

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isBusy {
                progressBarView
            } else {
                if let error = viewModel.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let outputURL = viewModel.lastOutputURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .controlSize(.small)
                }
            }

            if showLogPanel {
                DisclosureGroup("Show details", isExpanded: $logExpanded) {
                    LogView(text: viewModel.log)
                        .frame(minHeight: 160, maxHeight: 320)
                        .padding(.top, 4)
                }
                .font(.callout)
            }
        }
    }

    private var progressBarView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(viewModel.progressLabel)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let eta = viewModel.progressETA {
                    Text("ETA \(eta)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = viewModel.progressFraction {
                ProgressView(value: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    // MARK: - Version footer

    private var versionFooter: some View {
        HStack {
            Spacer()
            if let version = viewModel.ytdlpVersion {
                Text("yt-dlp \(version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Actions

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = outputDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectoryPath = url.path
        }
    }

    private func handleURLFieldSubmit() {
        if appMode == .advanced {
            viewModel.fetchFormats(cookiesFromBrowser: cookiesFromBrowser)
        } else {
            startBasicFlow()
        }
    }

    /// Basic mode's entire "Download" action: fetches formats silently (no
    /// separate "Fetch Formats" step the user has to trigger — see
    /// CLAUDE.md's "Basic mode flow"), then opens the resolution-picker
    /// sheet on success. A fetch failure already surfaces its own alert/
    /// lastError via `fetchFormatsAwaiting`, so there's nothing else to do
    /// here on failure.
    private func startBasicFlow() {
        Task {
            let success = await viewModel.fetchFormatsAwaiting(cookiesFromBrowser: cookiesFromBrowser)
            if success {
                showBasicResolutionSheet = true
            }
        }
    }
}

// MARK: - Basic mode resolution sheet

/// The entire Basic-mode decision surface: pick a resolution, optionally
/// flip on "Editing quality (ProRes)", press Go. Everything else (HDR
/// tone-mapping, codec/container choice, progress, notifications) is
/// automatic — see CLAUDE.md's "Basic mode flow".
private struct BasicResolutionSheet: View {
    let title: String?
    let choices: [BasicResolutionChoice]
    @Binding var useProRes: Bool
    @Binding var proResTier: ProResTier
    @Binding var deleteSourceAfterConversion: Bool
    let onGo: (BasicResolutionChoice) -> Void
    let onCancel: () -> Void

    @State private var selected: BasicResolutionChoice?

    /// Pre-selects "Best available" (always the last entry in `choices`
    /// when non-empty — see `BasicModeService.availableResolutionChoices`)
    /// so the sheet never opens in a dead-end state with Go disabled and
    /// nothing selected. Sensible defaults are the point of Basic mode.
    init(
        title: String?,
        choices: [BasicResolutionChoice],
        useProRes: Binding<Bool>,
        proResTier: Binding<ProResTier>,
        deleteSourceAfterConversion: Binding<Bool>,
        onGo: @escaping (BasicResolutionChoice) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.choices = choices
        self._useProRes = useProRes
        self._proResTier = proResTier
        self._deleteSourceAfterConversion = deleteSourceAfterConversion
        self.onGo = onGo
        self.onCancel = onCancel
        self._selected = State(initialValue: choices.last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose a Resolution")
                    .font(.headline)
                // Shown so the user is confirming a specific video, not an
                // anonymous URL, before picking a resolution.
                if let title {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if choices.isEmpty {
                ContentUnavailableView(
                    "No Formats Found",
                    systemImage: "exclamationmark.triangle",
                    description: Text("No downloadable video formats were found for this URL.")
                )
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(choices) { choice in
                        Button {
                            selected = choice
                        } label: {
                            HStack {
                                Image(systemName: selected == choice ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected == choice ? Color.accentColor : Color.secondary)
                                Text(choice.label)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(
                                selected == choice ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Editing quality (ProRes)", isOn: $useProRes)
                    Text("Much larger files, but scrubs smoothly in editing software.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if useProRes {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(ProResTier.allCases) { tier in
                                Button {
                                    proResTier = tier
                                } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: proResTier == tier ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(proResTier == tier ? Color.accentColor : Color.secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            HStack(spacing: 6) {
                                                Text(tier.label)
                                                if tier == .basicModeDefault {
                                                    Text("Recommended")
                                                        .font(.caption2.weight(.semibold))
                                                        .foregroundStyle(Color.accentColor)
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 1)
                                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                                }
                                            }
                                            Text(tier.basicModeTagline)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 6)
                                    .background(
                                        proResTier == tier ? Color.accentColor.opacity(0.1) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 4)

                        Toggle("Delete source file after conversion", isOn: $deleteSourceAfterConversion)
                        Text("The downloaded file is kept until the ProRes conversion finishes successfully.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Go") {
                    if let selected { onGo(selected) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("showLogPanel") private var showLogPanel = true
    @AppStorage("cookiesFromBrowser") private var cookiesFromBrowser: CookieBrowser = .none
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasAcknowledgedDisclaimer") private var hasAcknowledgedDisclaimer = false
    @AppStorage("debugForceShowSetupScreen") private var debugForceShowSetupScreen = false

    @State private var isUpdatingYTDLP = false
    @State private var updateResult: String?
    @State private var installedVersion: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show log panel", isOn: $showLogPanel)
                    .help("When off, the \"Show details\" disclosure is hidden from the main window entirely.")
            }

            Section {
                Picker("Use cookies from browser", selection: $cookiesFromBrowser) {
                    ForEach(CookieBrowser.allCases) { browser in
                        Text(browser.label).tag(browser)
                    }
                }
                Text("Safari and Firefox tend to be more reliable than Chromium-based browsers (Chrome, "
                    + "Brave, Edge) on macOS, which can have cookie database locking or encryption issues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Authentication")
            } footer: {
                Text("Cookie extraction from your browser is the only sign-in method Grab supports — it "
                    + "never asks for your YouTube username or password. Theres also a good chance it will NOT work first try enabling full disk access if it doesnt work, Either use a VPN to switch your virtual location or just try again later")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("yt-dlp") {
                if let installedVersion {
                    LabeledContent("Installed version", value: installedVersion)
                }
                HStack {
                    Button {
                        Task { await updateYTDLP() }
                    } label: {
                        if isUpdatingYTDLP {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Update yt-dlp")
                        }
                    }
                    .disabled(isUpdatingYTDLP)
                    Spacer()
                }
                if let updateResult {
                    Text(updateResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button("Show first-run setup screen") {
                    debugForceShowSetupScreen = true
                }
                Button("Reset first-run state") {
                    hasCompletedOnboarding = false
                    hasAcknowledgedDisclaimer = false
                }
            } header: {
                Text("Debug")
            } footer: {
                Text("\"Show first-run setup screen\" forces the setup sheet open regardless of dependency "
                    + "state or prior acknowledgement, for testing. \"Reset first-run state\" clears the "
                    + "onboarding-completed and disclaimer-acknowledged flags so the next launch behaves like "
                    + "a fresh install.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        // Same fix as the main window's Form(.grouped) sections — see the
        // comment on downloadOptionsSection above — plus an explicit opaque
        // background so hiding the Form's own vibrant one doesn't leave
        // this Settings window relying on an assumed-opaque default.
        .scrollContentBackground(.hidden)
        .padding(20)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await refreshInstalledVersion() }
    }

    private func refreshInstalledVersion() async {
        installedVersion = await YTDLPService.fetchVersion(runner: ProcessRunner())
    }

    private func updateYTDLP() async {
        isUpdatingYTDLP = true
        updateResult = nil

        guard FileManager.default.isExecutableFile(atPath: Tool.brew) else {
            updateResult = "Homebrew not found at \(Tool.brew)."
            isUpdatingYTDLP = false
            return
        }

        let result = await ProcessRunner().run(path: Tool.brew, arguments: ["upgrade", "yt-dlp"], qos: .utility)
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        updateResult = trimmed.isEmpty ? "yt-dlp is already up to date." : trimmed
        isUpdatingYTDLP = false
        await refreshInstalledVersion()
    }
}

// MARK: - Window accessor

/// Bridges to the hosting NSWindow so `ContentView` can actively resize it
/// per `AppMode` — SwiftUI has no pure-SwiftUI API to command a window
/// resize (`.frame(minHeight:)` only constrains manual resizing, it
/// doesn't move the current frame). An invisible, zero-drawing NSView
/// whose only job is reporting `.window` back up; safe to layer into
/// `.background()` since it draws nothing.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

// MARK: - Section card

/// Shared "gently raised surface" chrome for every top-level section
/// (Formats, Download, Output, Conversion) — a solid, neutral, *opaque*
/// card with a prominent icon+title header, soft shadow, and hairline
/// border. Purely a visual container: it changes nothing about what each
/// section contains or how it behaves, only how it's framed.
///
/// Deliberately **not** a `Material` (this used `.thickMaterial` originally,
/// which was the bug: a real window sitting over a colorful desktop
/// wallpaper sampled that color straight through every card, tinting the
/// whole app). `Color(nsColor: .controlBackgroundColor)` is a plain opaque
/// system color — it does not sample whatever's behind the window, so the
/// card reads the same neutral gray no matter what wallpaper or other
/// windows are behind Grab. Content areas are content, not window chrome;
/// translucency stays scoped to the toolbar/title-bar strip, which gets
/// its own native vibrancy for free from `.toolbar` being present (see
/// "Window chrome translucency" in CLAUDE.md) — nothing to do here.
private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .font(.headline)
            }
            content()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
    }
}

// MARK: - Log view

private struct LogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Log output will appear here…" : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("bottom")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .onChange(of: text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

#Preview {
    ContentView()
}
