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

    /// The most recent sign of life anywhere in this project.
    public var lastActivityAt: Date? {
        agents.compactMap(\.lastActivityAt).max()
    }

    public var isLive: Bool {
        agents.contains { $0.state != .idle } || !servers.isEmpty
    }

    /// True when everything here has gone quiet but is still running — the case
    /// worth surfacing, because it costs you memory and attention and you have
    /// forgotten it exists.
    public var isForgotten: Bool {
        !agents.isEmpty && agents.allSatisfy { $0.state == .idle }
    }

    /// "4d idle", "just now" — the single word that says whether to care.
    public var statusLabel: String {
        if let working = agents.first(where: { $0.state == .working }) {
            return working.lastActivityLabel
        }
        if let waiting = agents.first(where: { $0.state == .waiting }) {
            return waiting.lastActivityLabel
        }
        if let idle = agents.first {
            return "\(idle.lastActivityLabel) · idle"
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
                let leftLive = left.agents.contains { $0.state != .idle }
                let rightLive = right.agents.contains { $0.state != .idle }
                if leftLive != rightLive { return leftLive }
                return (left.lastActivityAt ?? .distantPast) > (right.lastActivityAt ?? .distantPast)
            }
    }
}
