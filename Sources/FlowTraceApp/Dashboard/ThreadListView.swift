import SwiftUI
import FlowTraceCore

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
