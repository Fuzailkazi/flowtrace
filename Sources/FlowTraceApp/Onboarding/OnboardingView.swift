import SwiftUI
import FlowTraceCore

/// First run.
///
/// The order matters: FlowTrace asks permission, names the exact directories it
/// will read, and only then scans. The user lands on a dashboard that already
/// has their real work in it — there is no empty state to fill in by hand.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Step { case welcome, shortcut, consent, scanning, review }
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
        .onChange(of: model.scanState) { _, state in
            if case .finished = state, step == .scanning { step = .review }
            if case .failed = state, step == .scanning { step = .review }
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .shortcut: shortcutStep
        case .consent: consent
        case .scanning: scanning
        case .review: review
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Spacer()
            BrandMarkView(size: 44)
            Text("FlowTrace")
                .font(.system(size: 26, weight: .semibold))
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
                        Text("FlowTrace can tell you what is running on this Mac right now. "
                             + "It counts processes and listening ports — no files are opened, "
                             + "nothing is stored, and nothing happens until you ask.")
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
            Text("FlowTrace shows what is actually happening on your machine — which agents are running and where each one stopped, which servers are still holding ports, what you had open — so you can pick up where you left off. It reads your coding-agent transcripts and git state — on this machine, "
                 + "read-only, nothing uploaded — and works out which pieces of work were "
                 + "started and never finished. You decide which ones are worth keeping.")
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

    /// Picking the key is a setup step, not a preference.
    ///
    /// It is the one control the whole product hangs on — a note you can add
    /// without opening the app — and leaving it to a default meant the key was
    /// one nobody chose.
    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Pick a key for adding notes")
                    .font(.system(size: 17, weight: .semibold))
                Text("Press it anywhere — in a browser, in your editor, mid-sentence — "
                     + "and a small panel appears over what you're doing. Type why you're "
                     + "there, press return, and it's written down. You never open "
                     + "FlowTrace to do it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your shortcut")
                                .font(.system(size: 12, weight: .medium))
                            Text("⌥Space already works. Click it to use something else.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShortcutRecorder(shortcut: Binding(
                            get: { model.lastChord },
                            set: {
                                model.lastChord = $0
                                model.captureTrigger = .chord($0)
                            }
                        ))
                    }

                    if let failure = model.shortcutFailure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("If pressing it does nothing, another app has claimed it — "
                             + "Spotlight, Raycast and Alfred all use keys like this one, "
                             + "and macOS gives it to whoever asked first without telling "
                             + "either of you. Record a different combination here if that "
                             + "happens.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer()
        }
        .padding(Theme.Space.xxl)
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("What FlowTrace may read")
                    .font(.system(size: 17, weight: .semibold))
                Text("Nothing is scanned until you turn it on here. You can change this at any "
                     + "time in Settings.")
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

            Card {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Label("What is read", systemImage: "eye")
                        .font(.system(size: 12, weight: .medium))
                    Text("The working directory, git branch, timestamps, the session's own title, "
                         + "and the prompts you typed. Assistant replies, file contents and tool "
                         + "output are never read. Keys, tokens and passwords are stripped from "
                         + "prompts before anything is stored.")
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
                         + "contents, and it begins only once you finish this setup.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("No account, no server, no telemetry. FlowTrace makes no network requests.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(Theme.Space.xxl)
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

    private var scanning: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Spacer()
            Text("Looking through your work…").font(.system(size: 17, weight: .semibold))
            if case .running(let phase, let fraction) = model.scanState {
                ProgressView(value: fraction) { Text(phase).font(.system(size: 12)) }
                    .frame(maxWidth: 420)
            } else {
                ProgressView().controlSize(.small)
            }
            Text("Reading transcripts and checking git state. Nothing is being changed.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Theme.Space.xxl)
    }

    @ViewBuilder
    private var review: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            switch model.scanState {
            case .failed(let message):
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("The scan didn't finish").font(.system(size: 17, weight: .semibold))
                    Text(message).font(.system(size: 12)).foregroundStyle(.red)
                    Text("You can still use FlowTrace and create threads by hand.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(Theme.Space.xxl)

            case .finished(let summary) where summary.proposals == 0:
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Nothing unfinished").font(.system(size: 17, weight: .semibold))
                    Text("FlowTrace read \(summary.sessions) sessions across "
                         + "\(summary.repositories) repositories and everything is committed "
                         + "and pushed. Create a thread when you start something you'll want "
                         + "to come back to.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.xxl)

            default:
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if case .finished(let summary) = model.scanState {
                        Text("\(summary.proposals) pieces of unfinished work")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Read \(summary.sessions) sessions across \(summary.repositories) "
                             + "repositories in \(String(format: "%.1f", summary.duration))s. "
                             + "Keep the ones worth coming back to.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding([.horizontal, .top], Theme.Space.xxl)

                ScrollView {
                    LazyVStack(spacing: Theme.Space.m) {
                        ForEach(model.proposals) { proposal in
                            ProposalCard(model: model, proposal: proposal)
                        }
                    }
                    .padding(.horizontal, Theme.Space.xxl)
                    .padding(.bottom, Theme.Space.l)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step == .consent {
                Button("Skip for now") { finish() }
                    .buttonStyle(.link)
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Get started") { step = .shortcut }
                    .buttonStyle(.borderedProminent)

            case .shortcut:
                Button("Use \(model.captureTrigger.displayString)") {
                    // Already registered at launch; saved here so a recorded
                    // change survives, and re-registered so a clash is reported
                    // on this screen rather than after it has gone.
                    model.captureTrigger.save()
                    model.reregisterTrigger()
                    step = .consent
                }
                .buttonStyle(.borderedProminent)
            case .consent:
                Button(model.consent.anyEnabled ? "Scan my work" : "Continue without scanning") {
                    model.consent.save()
                    if model.consent.anyEnabled {
                        step = .scanning
                        model.scan()
                    } else {
                        finish()
                    }
                }
                .buttonStyle(.borderedProminent)
            case .scanning:
                Button("Cancel") { finish() }
            case .review:
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.l)
    }

    private func finish() {
        // Nothing to settle about the shortcut here: ⌥Space is registered at
        // launch whether or not this screen is ever reached, and a recorded
        // change is saved by the step that recorded it.
        model.consent.hasCompletedOnboarding = true
        model.consent.save()
        // The master gate has just opened. Start what the user agreed to now
        // rather than making them relaunch to get it.
        model.startRecordingIfEnabled()
        model.refresh()
        // Land on the value: unfinished work when there is any, otherwise Now.
        // The previous default always landed on Now, hiding proposals behind
        // More → Unfinished where nobody found them.
        if !model.proposals.isEmpty {
            model.route = .dashboard
        } else {
            model.route = .now
        }
        dismiss()
    }

}
