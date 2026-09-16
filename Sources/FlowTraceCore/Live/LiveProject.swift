import Foundation

/// Everything happening in one place.
///
/// The first version listed agents and servers separately, which split a single
/// project across two lists: you could not see that `tulu` had an agent idle for
/// four days *and* a server still holding port 3000. Work happens in places, so
/// the place is the unit.
public struct LiveProject: Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String

    public var agents: [LiveAgent]
    public var servers: [LiveServer]
    /// What you said you were building here, if you've said.
    public var note: ProjectNote?

    public init(
        path: String, name: String, agents: [LiveAgent], servers: [LiveServer],
        note: ProjectNote? = nil
    ) {
        self.path = path
        self.name = name
        self.agents = agents
        self.servers = servers
        self.note = note
    }

    /// The most recent sign of life anywhere in this project.
    public var lastActivityAt: Date? {
        agents.compactMap(\.lastActivityAt).max()
    }

    public var isLive: Bool {
        agents.contains { $0.state.isActive } || !servers.isEmpty
    }

    /// The agents here FlowTrace was actually allowed to look at.
    ///
    /// Every verdict below is drawn from these and these only. A hidden agent
    /// is not evidence of anything except that permission was withheld, and a
    /// verdict built from one would be a statement about consent wearing the
    /// colours of a statement about work.
    public var readAgents: [LiveAgent] {
        agents.filter { !$0.transcriptHidden }
    }

    /// True when everything here has been quiet long enough that you have very
    /// likely forgotten it is running — the case worth surfacing, because it
    /// costs you memory and attention and you no longer know it exists.
    public var isForgotten: Bool {
        let seen = readAgents
        // Judged on when you were last here, not on when the agent last wrote.
        // Under the old rule a project you abandoned in July stayed off this
        // list indefinitely because a background agent kept touching its file.
        return !seen.isEmpty && seen.allSatisfy { $0.attentionState() == .forgotten }
    }

    /// Something is still running here and you have not been back in a long
    /// time. Worth saying out loud: it is both the most surprising row and the
    /// one that costs the most to leave alone.
    public var isRunningUnattended: Bool {
        readAgents.contains(where: \.isRunningUnattended)
    }

    /// How long since you were last here, across every agent in this place.
    public var awayFor: TimeInterval? {
        let dates = readAgents.compactMap(\.lastHumanActivityAt)
        guard let newest = dates.max() else { return nil }
        return Date().timeIntervalSince(newest)
    }

    /// Quiet, but not yet long enough to claim you have forgotten it. Shown
    /// differently, and never counted in the forgotten total.
    public var isQuiet: Bool {
        let seen = readAgents
        guard !seen.isEmpty, !isForgotten else { return false }
        return seen.allSatisfy { !$0.state.isActive }
    }

    /// The strongest thing happening here, which is what the row is sorted and
    /// coloured by.
    public var state: LiveAgent.State? {
        let seen = readAgents
        guard !seen.isEmpty else { return nil }
        for candidate in LiveAgent.State.allCases where seen.contains(where: { $0.state == candidate }) {
            return candidate
        }
        return nil
    }

    /// "4d idle", "just now" — the single word that says whether to care.
    public var statusLabel: String {
        // First in the chain, and guarded on a non-empty list: hidden agents
        // carry `.idle`, so without this they would fall through to
        // "unknown · idle", and without the guard `allSatisfy` would be
        // vacuously true and a server-only place would lose its own label.
        if !agents.isEmpty, agents.allSatisfy(\.transcriptHidden) {
            return "not reading transcripts"
        }
        if let unattended = readAgents.first(where: \.isRunningUnattended) {
            // Both facts, because either alone is misleading: the agent is
            // busy, and you have not been here for days.
            return "running · you were last here \(unattended.awayLabel ?? "a while") ago"
        }
        if let active = agents.first(where: { $0.state.isActive }) {
            return active.lastActivityLabel
        }
        if let quiet = agents.first, let state = state {
            return "\(quiet.lastActivityLabel) · \(state.label)"
        }
        return servers.isEmpty ? "" : "server only"
    }

    /// The last thing you asked any agent here.
    public var lastPrompt: String? {
        agents
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
            .compactMap(\.lastPrompt)
            .first
    }
}

public extension LiveState {
    /// Collapses agents and servers into the places they are running.
    ///
    /// Ordered by liveness first and recency second, so what is actually moving
    /// sits at the top and what has been forgotten sinks — without hiding it,
    /// because the forgotten things are half the value.
    func projects(notes: [String: ProjectNote] = [:]) -> [LiveProject] {
        var byPath: [String: LiveProject] = [:]

        for agent in agents {
            // An agent started somewhere that is not a project — the
            // filesystem root, the home folder, the Trash — is still running,
            // and `unplacedAgents` still reports it. What it does not get is a
            // row pretending to be a piece of work, because a place called `/`
            // with a timestamp on it invites you to resume something that was
            // never started.
            guard agent.place?.isProject != false else { continue }
            let path = agent.projectRoot
            byPath[path, default: LiveProject(
                path: path, name: agent.repositoryName, agents: [], servers: []
            )].agents.append(agent)
        }

        for server in servers {
            guard let path = server.projectRoot else { continue }
            byPath[path, default: LiveProject(
                path: path, name: server.projectName ?? server.processName,
                agents: [], servers: []
            )].servers.append(server)
        }

        return byPath.values
            .map { project in
                var project = project
                project.note = notes[project.path]
                project.servers.sort { $0.port < $1.port }
                project.agents.sort {
                    ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
                }
                return project
            }
            .sorted { left, right in
                let leftLive = left.agents.contains { $0.state.isActive }
                let rightLive = right.agents.contains { $0.state.isActive }
                if leftLive != rightLive { return leftLive }

                // Among the places that are not moving, the forgotten ones come
                // first. Sorting the quiet group by recency alone put the work
                // somebody stepped away from twenty minutes ago above the work
                // they abandoned four days ago — burying the exact thing the
                // screen exists to surface under the thing they still remember.
                if left.isForgotten != right.isForgotten { return left.isForgotten }

                // Within a group, oldest first when forgotten (the longest
                // abandoned is the most surprising) and newest first otherwise.
                let leftAt = left.lastActivityAt ?? .distantPast
                let rightAt = right.lastActivityAt ?? .distantPast
                return left.isForgotten ? leftAt < rightAt : leftAt > rightAt
            }
    }
}
