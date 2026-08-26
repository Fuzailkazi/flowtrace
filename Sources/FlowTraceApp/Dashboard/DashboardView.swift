import SwiftUI
import FlowTraceCore

/// The screen that answers, on return: what was I working on, what did I pause,
/// what changed, and what should I pick up next.
struct DashboardView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let failure = model.loadFailure {
                    Card {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }

                if model.threads.isEmpty && model.proposals.isEmpty {
                    emptyDashboard
                } else {
                    needsAttention
                    continueSection
                    section("Active", model.activeThreads, icon: "circle.fill")
                    section("Blocked", model.blockedThreads, icon: "exclamationmark.octagon")
                    section("Paused", model.pausedThreads, icon: "pause.circle")
                    recentCaptures
                }
            }
            .padding(Theme.Space.xl)
        }
        .navigationTitle("Resume")
    }

    // MARK: - Detected work

    @ViewBuilder
    private var needsAttention: some View {
        if !model.proposals.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader(
                    title: "Needs attention",
                    count: model.proposals.count,
                    subtitle: "found in your repositories — confirm to keep, dismiss to hide"
                )
                ForEach(model.proposals) { proposal in
                    ProposalCard(model: model, proposal: proposal)
                }
            }
        }
    }

    @ViewBuilder
    private var continueSection: some View {
        let threads = model.continueWhereYouLeftOff
        if !threads.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader(title: "Continue where you left off")
                ForEach(threads) { thread in
                    ThreadCard(model: model, thread: thread)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ threads: [WorkThread], icon: String) -> some View {
        if !threads.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader(title: title, count: threads.count)
                ForEach(threads) { thread in
                    ThreadCard(model: model, thread: thread)
                }
            }
        }
    }

    @ViewBuilder
    private var recentCaptures: some View {
        if !model.recentTabs.isEmpty || !model.recentCode.isEmpty {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                if !model.recentTabs.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        SectionHeader(title: "Recent tabs", count: model.recentTabs.count)
                        Card {
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                ForEach(model.recentTabs.prefix(5)) { tab in
                                    TabRow(model: model, tab: tab)
                                }
                            }
                        }
                    }
                }
                if !model.recentCode.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        SectionHeader(title: "Recent code", count: model.recentCode.count)
                        Card {
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                ForEach(model.recentCode.prefix(5)) { code in
                                    CodeRow(model: model, code: code)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty

    private var emptyDashboard: some View {
        VStack(spacing: Theme.Space.l) {
            if model.consent.anyEnabled {
                EmptyState(
                    icon: "checkmark.circle",
                    title: "Nothing unfinished",
                    message: "Every repository FlowTrace can see is committed and pushed. "
                        + "Create a thread when you start something you'll want to come back to.",
                    actionLabel: "New work thread",
                    action: { NotificationCenter.default.post(name: .flowtraceNewThread, object: nil) }
                )
            } else {
                EmptyState(
                    icon: "sparkle.magnifyingglass",
                    title: "Let FlowTrace find your unfinished work",
                    message: "Turn on a source in Settings and FlowTrace will read your coding-agent "
                        + "sessions and git state — locally, read-only — to work out what you started "
                        + "and never finished.",
                    actionLabel: "Open Settings",
                    action: { model.route = .settings }
                )
            }
        }
    }
}
