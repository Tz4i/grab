import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @Environment(\.openSettings) private var openSettings

    @AppStorage("outputDirectoryPath") private var outputDirectoryPath: String =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()

    @AppStorage("convertToProRes") private var convertToProRes = false
    @AppStorage("proResTier") private var proResTier: ProResTier = .hq
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            formatsSection
            colorIndicatorBadge
            downloadOptionsSection
            outputSection
            statusSection
            versionFooter
        }
        .padding(12)
        .frame(minWidth: 820, minHeight: 620)
        .toolbar { toolbarContent }
        .task {
            NotificationService.requestAuthorizationIfNeeded()
            viewModel.checkYTDLPVersion()
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
                        viewModel.retryWithBestQualitySelector(
                            outputDir: outputDirectoryURL,
                            convertToProRes: convertToProRes,
                            tier: proResTier,
                            downscale4K: downscale4K,
                            deleteSourceAfterConversion: deleteSourceAfterConversion,
                            useHardwareAcceleration: useHardwareAcceleration,
                            preferMP4: preferMP4,
                            cookiesFromBrowser: cookiesFromBrowser,
                            sleepInterval: sleepInterval
                        )
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
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            TextField("YouTube URL", text: $viewModel.urlString)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260, idealWidth: 420)
                .disabled(viewModel.isBusy)
                .onSubmit { viewModel.fetchFormats(cookiesFromBrowser: cookiesFromBrowser) }
        }

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
            Button {
                viewModel.startDownload(
                    outputDir: outputDirectoryURL,
                    convertToProRes: convertToProRes,
                    tier: proResTier,
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
        }
    }

    // MARK: - Formats

    private var formatsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(6)
        } label: {
            Label("Formats", systemImage: "film")
                .font(.headline)
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
        Form {
            Section("Download") {
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
        .fixedSize(horizontal: false, vertical: true)
        .disabled(viewModel.isBusy)
    }

    // MARK: - Output section

    private var outputSection: some View {
        Form {
            Section("Output") {
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

            Section("ProRes") {
                Toggle("Convert to ProRes after download", isOn: $convertToProRes)

                if convertToProRes {
                    Picker("Tier", selection: $proResTier) {
                        ForEach(ProResTier.allCases) { tier in
                            Text(tier.label).tag(tier)
                        }
                    }
                    Toggle("Downscale to 4K (3840×2160)", isOn: $downscale4K)
                    Toggle("Delete source file after conversion", isOn: $deleteSourceAfterConversion)
                    Toggle("Use hardware acceleration", isOn: $useHardwareAcceleration)
                        .help("Uses the Mac's hardware ProRes encoder (prores_videotoolbox) when available, automatically falling back to software encoding (prores_ks) if it fails.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(viewModel.isBusy)
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
                        .frame(minHeight: 160)
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
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("showLogPanel") private var showLogPanel = true
    @AppStorage("cookiesFromBrowser") private var cookiesFromBrowser: CookieBrowser = .none

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
                    + "never asks for your YouTube username or password.")
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
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 440)
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
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))
            .onChange(of: text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

#Preview {
    ContentView()
}
