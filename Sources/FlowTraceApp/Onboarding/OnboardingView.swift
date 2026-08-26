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

    enum Step { case welcome, consent, scanning, review }
    @State private var step: Step = .welcome

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
        case .consent: consent
        case .scanning: scanning
        case .review: review
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Spacer()
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("FlowTrace")
                .font(.system(size: 26, weight: .semibold))
            Text("You start things and don't finish them. FlowTrace finds those things.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text("It reads your coding-agent transcripts and git state — on this machine, "
                 + "read-only, nothing uploaded — and works out which pieces of work were "
                 + "started and never finished. You decide which ones are worth keeping.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                         + "and the prompts you typed. Assistant replies, file contents, tool "
                         + "output and credentials are never read or stored.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Where it goes", systemImage: "internaldrive")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.top, Theme.Space.xs)
                    Text(FlowTraceDatabase.defaultURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
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
                        Text(abbreviate(path))
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
                Button("Get started") { step = .consent }
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
        model.consent.hasCompletedOnboarding = true
        model.consent.save()
        model.refresh()
        dismiss()
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
