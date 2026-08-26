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

// MARK: - Rows

struct TabRow: View {
    @Bindable var model: AppModel
    let tab: BrowserContext

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "safari").font(.system(size: 11)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.pageTitle).font(.system(size: 12)).lineLimit(1)
                HStack(spacing: Theme.Space.xs) {
                    Text(tab.host).font(.system(size: 10)).foregroundStyle(.tertiary)
                    if !tab.note.isEmpty {
                        Text("· \(tab.note)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            if let threadId = tab.workThreadId, let thread = model.thread(id: threadId) {
                Button(thread.title) { model.route = .thread(threadId) }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .lineLimit(1)
            } else {
                Chip(text: "unfiled", color: .orange)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let url = URL(string: tab.url) { NSWorkspace.shared.open(url) } }
    }
}

struct CodeRow: View {
    @Bindable var model: AppModel
    let code: CodeContext

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.xs) {
                    Text(code.repositoryName).font(.system(size: 12))
                    if let branch = code.branch {
                        Text(branch).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if let agent = code.agentName {
                        Chip(text: agent.label, color: .purple)
                    }
                }
                if !code.note.isEmpty {
                    Text(code.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let threadId = code.workThreadId, let thread = model.thread(id: threadId) {
                Button(thread.title) { model.route = .thread(threadId) }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Filtered lists

struct ThreadListView: View {
    @Bindable var model: AppModel
    let status: ThreadStatus

    private var threads: [WorkThread] { model.threads(for: status) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                if threads.isEmpty {
                    EmptyState(
                        icon: emptyIcon,
                        title: "No \(status.label.lowercased()) threads",
                        message: emptyMessage
                    )
                } else {
                    ForEach(threads) { thread in
                        ThreadCard(model: model, thread: thread, showResume: status != .completed)
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
        .navigationTitle(status.label)
    }

    private var emptyIcon: String {
        switch status {
        case .active: "circle.dashed"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        }
    }

    private var emptyMessage: String {
        switch status {
        case .active: "Threads you're working on now will show here."
        case .paused: "Pause a thread when you step away from it and want it out of the way."
        case .completed: "Finished threads stay here so you can look back at what you decided."
        }
    }
}

struct RecentCapturesView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if model.recentTabs.isEmpty && model.recentCode.isEmpty {
                    EmptyState(
                        icon: "tray",
                        title: "Nothing captured yet",
                        message: "Capture the tabs you have open, or attach a repository, "
                            + "and they'll be listed here with the thread they belong to.",
                        actionLabel: "Capture context",
                        action: { NotificationCenter.default.post(name: .flowtraceCapture, object: nil) }
                    )
                } else {
                    if !model.recentTabs.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            SectionHeader(title: "Browser tabs", count: model.recentTabs.count)
                            Card {
                                VStack(alignment: .leading, spacing: Theme.Space.m) {
                                    ForEach(model.recentTabs) { tab in
                                        TabRow(model: model, tab: tab)
                                    }
                                }
                            }
                        }
                    }
                    if !model.recentCode.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            SectionHeader(title: "Repositories and sessions", count: model.recentCode.count)
                            Card {
                                VStack(alignment: .leading, spacing: Theme.Space.m) {
                                    ForEach(model.recentCode) { code in
                                        CodeRow(model: model, code: code)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
        .navigationTitle("Recent Captures")
    }
}

struct SearchResultsView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                if model.searchResults.isEmpty {
                    EmptyState(
                        icon: "magnifyingglass",
                        title: "No matches for \"\(model.searchText)\"",
                        message: "Search covers thread titles, intents, next steps, blockers, "
                            + "notes, page titles, URLs, repository names and agent names."
                    )
                } else {
                    SectionHeader(title: "Results", count: model.searchResults.count)
                    ForEach(model.searchResults) { hit in
                        SearchHitRow(model: model, hit: hit)
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
        .navigationTitle("Search")
    }
}

struct SearchHitRow: View {
    @Bindable var model: AppModel
    let hit: SearchHit

    var body: some View {
        Card(padding: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if let thread = model.thread(id: hit.threadId), hit.kind != .thread {
                    Text(thread.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.searchText = ""
            model.route = .thread(hit.threadId)
        }
    }

    private var icon: String {
        switch hit.kind {
        case .thread: "point.3.filled.connected.trianglepath.dotted"
        case .tab: "safari"
        case .code: "folder"
        case .note: "note.text"
        }
    }
}
