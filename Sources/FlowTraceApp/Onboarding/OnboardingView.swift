import SwiftUI
import FlowTraceCore

/// First run.
///
/// A quick introduction, then explicit source consent. Now is the first real
/// screen; looking through past sessions is available there when useful.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Step { case welcome, consent }
    @State private var step: Step = .welcome

    /// What is actually running on this Mac, for the opening sentence. Nil while
    /// the census is in flight; `liveFailure` when it could not be taken.
    @State private var liveSummary: String?
    @State private var liveFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .consent: consent
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Spacer()
            BrandMarkView(size: 44)
            Text("FlowTrace")
                .font(.system(size: 26, weight: .semibold))
            Text("Find the coding work you left behind, across repositories and agents.")
                .font(.system(size: 17, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            // Measured, not written — but only when asked for. Counting
            // processes opens no transcript and needs no permission, yet it is
            // still looking at this Mac, and the promise is that nothing is
            // looked at before you say so. Pressing the button is saying so.
            Group {
                if let liveSummary {
                    Text(liveSummary)
                } else if let liveFailure {
                    Text("FlowTrace couldn't read what's running on this Mac — \(liveFailure)")
                } else if censusRunning {
                    Text("Counting what's running…")
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("See what's running on this Mac right now. This optional count "
                             + "reads process information, opens no agent transcripts, and "
                             + "isn't saved.")
                        Button("Count what's running") {
                            Task { await readCensus() }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(liveFailure == nil ? .secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
            Text("Choose which local agent histories FlowTrace may read next. Then open a "
                 + "project to recover its context, or look through older sessions when you need to.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(Theme.Space.xxl)
    }

    /// Counts what is running, off the main actor — `pgrep` and `lsof` are
    /// subprocesses. A failure is shown rather than papered over with a number
    /// nobody measured.
    @State private var censusRunning = false

    private func readCensus() async {
        guard liveSummary == nil, liveFailure == nil, !censusRunning else { return }
        censusRunning = true
        defer { censusRunning = false }
        let census = await Task.detached(priority: .userInitiated) {
            () -> Result<(agents: Int, servers: Int), Error> in
            do { return .success(try LiveStateReader().readCensus()) }
            catch { return .failure(error) }
        }.value
        switch census {
        case .success(let counts):
            liveSummary = LiveState.firstRunSummary(agents: counts.agents, servers: counts.servers)
        case .failure(let error):
            liveFailure = error.localizedDescription
        }
    }

    private var consent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("What FlowTrace may read")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Choose which local session histories FlowTrace may read. "
                         + "You can change this at any time in Settings.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                if let failure = model.shortcutFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                sourceToggle(
                    isOn: $model.consent.claudeCode,
                    title: "Claude Code",
                    paths: ClaudeCodeAdapter().searchPaths,
                    available: ClaudeCodeAdapter().isAvailable
                )
                sourceToggle(
                    isOn: $model.consent.codex,
                    title: "Codex CLI",
                    paths: CodexAdapter().searchPaths,
                    available: CodexAdapter().isAvailable
                )
                sourceToggle(
                    isOn: $model.consent.openCode,
                    title: "OpenCode (live context)",
                    paths: [OpenCodeStore.defaultDatabase.path],
                    available: OpenCodeStore.isInstalled
                )

                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Label("What is read", systemImage: "eye")
                            .font(.system(size: 12, weight: .medium))
                        Text("Claude Code and Codex: working directory, timestamps, session title "
                             + "and your prompts. OpenCode: working directory, timestamps and session "
                             + "title. FlowTrace does not save assistant replies or tool output. "
                             + "Sensitive values are redacted before supported text is stored.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Label("Where it goes", systemImage: "internaldrive")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.top, Theme.Space.xs)
                        Text(FlowTraceDatabase.defaultURL.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Label("What is seen without reading a file", systemImage: "cpu")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.top, Theme.Space.xs)
                        Text("Which coding agents and local servers are running, and the project "
                             + "each was started from. This is process information, not file "
                             + "contents. If you chose the optional count on the previous screen, "
                             + "FlowTrace read it once without saving it. Ongoing reading begins "
                             + "when you finish setup.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("No account or telemetry. Your work stays on this Mac.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.Space.xxl)
        }
    }

    private func sourceToggle(
        isOn: Binding<Bool>, title: String, paths: [String], available: Bool
    ) -> some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Toggle("", isOn: isOn).labelsHidden().disabled(!available)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        if !available { Chip(text: "not installed", color: .secondary) }
                    }
                    ForEach(paths, id: \.self) { path in
                        Text(path.abbreviatingHome)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
        }
        .opacity(available ? 1 : 0.55)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step == .consent {
                Button("Continue without sources") {
                    model.consent.claudeCode = false
                    model.consent.codex = false
                    model.consent.openCode = false
                    finish()
                }
                    .buttonStyle(.link)
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Continue") { step = .consent }
                    .buttonStyle(.borderedProminent)
            case .consent:
                Button("See what's happening now") { finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.l)
    }

    private func finish() {
        // The default capture key is registered at launch. People can change
        // it in Settings after seeing the app's main value.
        model.consent.hasCompletedOnboarding = true
        model.consent.save()
        // The master gate has just opened. Start what the user agreed to now
        // rather than making them relaunch to get it.
        model.startRecordingIfEnabled()
        model.refresh()
        model.route = .now
        dismiss()
    }

}
