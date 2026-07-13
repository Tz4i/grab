import SwiftUI

/// First-run setup sheet: dependency status + install helpers, plus the
/// disclaimers the user must acknowledge before continuing. Combined into
/// one screen deliberately — both halves gate the same "is Grab ready and
/// has the user been informed" concern, and re-showing it later (a tool
/// went missing, or Debug → "Show first-run setup screen") should always
/// present the full picture, not a partial one.
struct DependencySetupView: View {
    @ObservedObject var viewModel: DependencySetupViewModel
    @Binding var hasAcknowledgedDisclaimer: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    dependencySection
                    Divider()
                    disclaimerSection
                }
                .padding(20)
            }
            .defaultScrollAnchor(.top)
            Divider()
            footer
        }
        .frame(width: 560, height: 660)
        .interactiveDismissDisabled(!hasAcknowledgedDisclaimer || !allRequiredFound)
        .task { await viewModel.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Grab needs a few command-line tools", systemImage: "wrench.and.screwdriver")
                .font(.title3.weight(.semibold))
            Text("Grab is a graphical front end for these tools — it can't download or convert anything "
                + "without them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Dependencies

    private var dependencySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dependencies")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(viewModel.statuses) { status in
                    dependencyRow(status)
                    if status.id != viewModel.statuses.last?.id {
                        Divider()
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            installHelp

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Check again", systemImage: "arrow.clockwise")
            }
        }
    }

    private func dependencyRow(_ status: DependencyStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.isFound ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isFound ? Color.green : Color.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.kind.displayName)
                    .font(.body.weight(.medium))
                Text(status.kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if status.isFound {
                Text(status.version ?? "found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            } else {
                Text("Missing")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var installHelp: some View {
        let homebrewMissing = viewModel.statuses.first(where: { $0.kind == .homebrew })?.isFound == false

        if homebrewMissing {
            homebrewMissingCallout
        } else if !viewModel.installableMissingFormulas.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await viewModel.installMissingTools() }
                } label: {
                    if viewModel.isInstalling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                        }
                    } else {
                        Label(
                            "Install missing tools (\(viewModel.installableMissingFormulas.joined(separator: ", ")))",
                            systemImage: "arrow.down.circle"
                        )
                    }
                }
                .disabled(viewModel.isInstalling)

                if !viewModel.installLog.isEmpty {
                    ScrollView {
                        Text(viewModel.installLog)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 100)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var homebrewMissingCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Homebrew is missing")
                .font(.subheadline.weight(.semibold))
            Text("Homebrew is the package manager Grab uses to install and locate the tools above. "
                + "Installing it requires admin permission, so Grab won't run the installer silently — "
                + "copy the official command below, or launch it in a visible Terminal window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(DependencyService.homebrewInstallCommand)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button {
                    viewModel.copyHomebrewInstallCommand()
                } label: {
                    Label("Copy command", systemImage: "doc.on.doc")
                }
                Button {
                    viewModel.installHomebrewInTerminal()
                } label: {
                    Label("Install Homebrew…", systemImage: "terminal")
                }
                Link("brew.sh", destination: URL(string: "https://brew.sh")!)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Disclaimers

    private var disclaimerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Before you continue")
                .font(.headline)

            disclaimerBlock(
                title: "Terms of Service",
                body: "Downloading content from YouTube may violate YouTube's Terms of Service. This tool is "
                    + "provided for personal use with content you have the right to download. Use at your own risk."
            )
            disclaimerBlock(
                title: "Copyright",
                body: "You are responsible for how you use downloaded content. Respect copyright and the rights "
                    + "of content creators."
            )
            disclaimerBlock(
                title: "AI assistance",
                body: "AI was used to assist in the creation of this app."
            )
            disclaimerBlock(
                title: "No warranty",
                body: "This software is provided as-is, without warranty of any kind. It is not affiliated with, "
                    + "endorsed by, or connected to YouTube, Google, or Apple."
            )
            disclaimerBlock(
                title: "Third-party tools",
                body: "This app is a graphical interface for yt-dlp and ffmpeg, which are independent open-source "
                    + "projects. Their behavior and availability are outside this app's control."
            )
        }
    }

    private func disclaimerBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    /// Gates the checkbox itself, not just Continue — you can't even check
    /// "I understand" until the required tools are actually present. If the
    /// sheet re-appears later because a previously-installed tool went
    /// missing again, this also re-locks a checkbox that was already
    /// checked from a prior session (the bound value stays true, but the
    /// control itself is inert until fixed).
    private var allRequiredFound: Bool {
        viewModel.missingRequired.isEmpty
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $hasAcknowledgedDisclaimer) {
                Text("I understand")
            }
            .toggleStyle(.checkbox)
            .disabled(!allRequiredFound)

            if !allRequiredFound {
                Text("Install the missing tools above before continuing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Continue") {
                    onContinue()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasAcknowledgedDisclaimer || !allRequiredFound)
            }
        }
        .padding(16)
    }
}
