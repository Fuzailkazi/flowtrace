import SwiftUI
import FlowTraceCore

/// Everywhere you've been working, grouped by repository.
///
/// A row of *things*, not of filters: the repositories the day's coding sessions
/// actually touched, with the branch and how much is uncommitted. Glancing at it
/// answers "what am I in the middle of". It used to be a sidebar; the shell
/// owns the sidebar now, so this sits under the day's activity strip.
struct SessionsRail: View {
    @Bindable var model: AppModel
    let day: Date
    var onSelect: (ActivityEvent) -> Void

    @State private var groups: [RepoGroup] = []
    /// A failed read. This rail collapses to nothing when it has no groups, so
    /// without this a broken read is completely invisible.
    @State private var failure: String?

    struct RepoGroup: Identifiable {
        var id: String { name }
        var name: String
        var sessions: [ActivityEvent]
        var totalMessages: Int
        var lastAt: Date
        /// Populated off the main actor — git is a subprocess.
        var dirtyCount: Int?
        var branch: String?
        var path: String?
    }

    var body: some View {
        Group {
            if let failure {
                LoadFailureLine(message: "Couldn't read where you worked — \(failure)")
            } else if groups.isEmpty {
                // Nothing to say, and nothing to take up room saying it.
                Color.clear.frame(height: 0)
            } else {
                VStack(alignment: .leading, spacing: Journal.Space.s) {
                    Text("WHERE YOU WORKED")
                        .font(.caption())
                        .tracking(1.0)
                        .foregroundStyle(Journal.inkSoft)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Journal.Space.s) {
                            ForEach(groups) { group in
                                repoChip(group)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .task(id: day) { load() }
        .onChange(of: model.activityRevision) { _, _ in load() }
    }

    // MARK: - One repository

    private func repoChip(_ group: RepoGroup) -> some View {
        Button {
            // The newest session is the one you are most likely to be in.
            if let newest = group.sessions.first { onSelect(newest) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Journal.Space.s) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Journal.pen)
                    Text(group.name)
                        .font(.observed(13, weight: .semibold))
                        .foregroundStyle(Journal.ink)
                        .lineLimit(1)

                    Spacer(minLength: Journal.Space.s)

                    Text("\(group.sessions.count) session\(group.sessions.count == 1 ? "" : "s")")
                        .font(.observed(10.5, weight: .medium))
                        .foregroundStyle(Journal.pen)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Journal.penSoft, in: Capsule())
                }

                HStack(spacing: 6) {
                    if let branch = group.branch {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                        Text(branch)
                            .font(.mono(10.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let dirty = group.dirtyCount, dirty > 0 {
                        if group.branch != nil { Text("·") }
                        Text("\(dirty) uncommitted")
                            .font(.observed(10.5, weight: .medium))
                            .foregroundStyle(Journal.amber)
                    }
                    if group.branch == nil && (group.dirtyCount ?? 0) == 0 {
                        Text(group.sessions.first?.startedAt ?? day,
                             format: .dateTime.hour().minute())
                            .font(.mono(10.5))
                    }
                }
                .foregroundStyle(Journal.inkSoft)
            }
            .padding(.horizontal, Journal.Space.m)
            .padding(.vertical, 10)
            .frame(minWidth: 180, maxWidth: 260, alignment: .leading)
            .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
            .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: Journal.Radius.card))
        }
        .buttonStyle(.plain)
        .help(group.path ?? group.name)
    }

    // MARK: - Data

    private func load() {
        // The rail wants sessions whether or not you wrote about them, so it asks
        // for the raw record rather than the written-only timeline.
        let events: [ActivityEvent]
        do {
            events = try model.store.allActivity(on: day, minimumSeconds: 0)
                .filter { $0.kind == .agentSession }
            failure = nil
        } catch {
            failure = error.localizedDescription
            return
        }

        let byRepo = Dictionary(grouping: events) { $0.target ?? "elsewhere" }
        var built = byRepo.map { name, sessions in
            RepoGroup(
                name: name,
                sessions: sessions.sorted { $0.startedAt > $1.startedAt },
                totalMessages: sessions.compactMap { Int($0.metadata["messages"] ?? "") }.reduce(0, +),
                lastAt: sessions.map(\.startedAt).max() ?? day,
                path: sessions.compactMap { $0.metadata["cwd"] }.first
            )
        }
        built.sort { $0.lastAt > $1.lastAt }
        groups = built

        enrichWithGit(built)
    }

    /// Git state per repository, off the main actor — each probe is a subprocess.
    private func enrichWithGit(_ built: [RepoGroup]) {
        let paths = built.compactMap { group in group.path.map { (group.name, $0) } }
        guard !paths.isEmpty else { return }

        Task.detached(priority: .utility) {
            let probe = GitProbe()
            var states: [String: (Int, String)] = [:]
            for (name, path) in paths {
                guard let state = probe.probe(path) else { continue }
                states[name] = (state.dirtyFileCount, state.branch)
            }
            let finishedStates = states
            await MainActor.run {
                groups = groups.map { group in
                    var group = group
                    if let (dirty, branch) = finishedStates[group.name] {
                        group.dirtyCount = dirty
                        group.branch = branch
                    }
                    return group
                }
            }
        }
    }
}
