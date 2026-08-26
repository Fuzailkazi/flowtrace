import SwiftUI
import FlowTraceCore

/// Everywhere you've been working, grouped by repository.
///
/// This is a rail of *things*, not of filters. The sidebar that used to be here
/// listed All / Active / Paused / Completed, which told you nothing you didn't
/// already know; this lists the sessions and repositories the day actually
/// touched, so glancing left answers "what am I in the middle of".
struct SessionsRail: View {
    @Bindable var model: AppModel
    let day: Date
    var onSelect: (ActivityEvent) -> Void

    @State private var groups: [RepoGroup] = []
    @State private var expanded: Set<String> = []

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                heading

                if groups.isEmpty {
                    Text("No coding sessions on this day.")
                        .font(.observed(12))
                        .foregroundStyle(Journal.inkSoft)
                        .padding(.horizontal, Journal.Space.m)
                        .padding(.top, Journal.Space.s)
                } else {
                    ForEach(groups) { group in
                        repoBlock(group)
                    }
                }
            }
            .padding(.bottom, Journal.Space.l)
        }
        .background(Journal.paperDeep)
        .task(id: day) { load() }
        .onChange(of: model.activityRevision) { _, _ in load() }
    }

    private var heading: some View {
        HStack {
            Text("Where you worked")
                .font(.observed(10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Journal.inkSoft)
            Spacer()
        }
        .padding(.horizontal, Journal.Space.m)
        .padding(.top, Journal.Space.l)
        .padding(.bottom, Journal.Space.s)
    }

    // MARK: - One repository

    private func repoBlock(_ group: RepoGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(group.name)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Journal.Space.s) {
                    Image(systemName: expanded.contains(group.name)
                          ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Journal.inkSoft)
                        .frame(width: 9)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.observed(13, weight: .semibold))
                            .foregroundStyle(Journal.ink)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            if let branch = group.branch {
                                Text(branch).lineLimit(1)
                            }
                            if let dirty = group.dirtyCount, dirty > 0 {
                                if group.branch != nil { Text("·") }
                                Text("\(dirty) uncommitted").foregroundStyle(Journal.amber)
                            }
                        }
                        .font(.observed(10.5))
                        .foregroundStyle(Journal.inkSoft)
                    }

                    Spacer(minLength: 4)

                    Text("\(group.sessions.count)")
                        .font(.observed(10.5, weight: .medium))
                        .foregroundStyle(Journal.pen)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Journal.penSoft, in: Capsule())
                }
                .padding(.horizontal, Journal.Space.m)
                .padding(.vertical, Journal.Space.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.contains(group.name) {
                ForEach(group.sessions) { session in
                    sessionRow(session)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Divider().overlay(Journal.rule).padding(.horizontal, Journal.Space.m)
        }
    }

    /// A session is worth listing only if you can tell what it was about.
    private func sessionRow(_ session: ActivityEvent) -> some View {
        Button {
            onSelect(session)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.metadata["about"] ?? "\(session.appName) session")
                    .font(.observed(12))
                    .foregroundStyle(Journal.inkMid)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 5) {
                    Text(session.startedAt, format: .dateTime.hour().minute())
                        .monospacedDigit()
                    if let messages = session.metadata["messages"] {
                        Text("·")
                        Text("\(messages) messages")
                    }
                    if let note = session.note, !note.isEmpty {
                        Text("·")
                        Image(systemName: "quote.opening").font(.system(size: 7))
                    }
                }
                .font(.observed(10))
                .foregroundStyle(Journal.inkSoft)
            }
            .padding(.leading, Journal.Space.m + 17)
            .padding(.trailing, Journal.Space.m)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ name: String) {
        if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
    }

    // MARK: - Data

    private func load() {
        let events = ((try? model.store.activity(on: day, minimumSeconds: 0)) ?? [])
            .filter { $0.kind == .agentSession }

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

        // Most recent repository opens by default — the one you're likely in.
        if expanded.isEmpty, let first = built.first { expanded.insert(first.name) }

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
            await MainActor.run {
                groups = groups.map { group in
                    var group = group
                    if let (dirty, branch) = states[group.name] {
                        group.dirtyCount = dirty
                        group.branch = branch
                    }
                    return group
                }
            }
        }
    }
}
