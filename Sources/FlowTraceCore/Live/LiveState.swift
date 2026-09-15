import Foundation

/// A coding agent running on this machine right now.
public struct LiveAgent: Identifiable, Hashable, Sendable {
    /// How long ago the transcript was last written to, turned into a verdict.
    public enum State: String, Sendable {
        /// Something was written in the last couple of minutes.
        case working
        /// Recently active, and almost certainly sitting waiting for you.
        case waiting
        /// Nothing for hours or days. Still running, still holding resources.
        case idle
    }

    public var id: String { "\(agent.rawValue):\(pid)" }
    public var pid: Int32
    public var agent: AgentName
    public var workingDirectory: String
    /// The repository root, so a server started in `tulu/frontend` and an agent
    /// running in `tulu` are recognised as the same project.
    public var projectRoot: String
    public var repositoryName: String
    public var branch: String?

    public var lastPrompt: String?
    public var lastActivityAt: Date?
    public var state: State
    public var sessionId: String?
    /// Your own note about this piece of work, if you've written one.
    public var note: String?

    /// True when FlowTrace found the process but has not been allowed to open
    /// its transcript. The row still says something honest — an agent is
    /// running here — without claiming to know what it is doing.
    public var transcriptHidden: Bool

    public init(
        pid: Int32, agent: AgentName, workingDirectory: String, projectRoot: String,
        repositoryName: String, branch: String? = nil, lastPrompt: String? = nil,
        lastActivityAt: Date? = nil, state: State, sessionId: String? = nil,
        note: String? = nil, transcriptHidden: Bool = false
    ) {
        self.pid = pid
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.projectRoot = projectRoot
        self.repositoryName = repositoryName
        self.branch = branch
        self.lastPrompt = lastPrompt
        self.lastActivityAt = lastActivityAt
        self.state = state
        self.sessionId = sessionId
        self.note = note
        self.transcriptHidden = transcriptHidden
    }

    public var idleFor: TimeInterval {
        guard let lastActivityAt else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(lastActivityAt)
    }

    /// "2m ago", "4d ago" — the honest signal, and usually the surprising one.
    public var lastActivityLabel: String {
        if transcriptHidden { return "not reading this one" }
        guard let lastActivityAt else { return "unknown" }
        let seconds = Date().timeIntervalSince(lastActivityAt)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

/// Something listening on a local port — usually a dev server you started and
/// forgot about.
public struct LiveServer: Identifiable, Hashable, Sendable {
    public var id: String { "\(pid):\(port)" }
    public var pid: Int32
    public var port: UInt16
    public var processName: String
    public var workingDirectory: String?
    /// The repository root — see `LiveAgent.projectRoot`.
    public var projectRoot: String?
    public var projectName: String?

    public init(
        pid: Int32, port: UInt16, processName: String,
        workingDirectory: String? = nil, projectRoot: String? = nil,
        projectName: String? = nil
    ) {
        self.pid = pid
        self.port = port
        self.processName = processName
        self.workingDirectory = workingDirectory
        self.projectRoot = projectRoot
        self.projectName = projectName
    }

    public var address: String { "http://localhost:\(port)" }
}

/// The state of the machine at a moment.
public struct LiveState: Sendable {
    public var agents: [LiveAgent] = []
    public var servers: [LiveServer] = []
    public var capturedAt: Date = Date()

    public init(
        agents: [LiveAgent] = [], servers: [LiveServer] = [], capturedAt: Date = Date()
    ) {
        self.agents = agents
        self.servers = servers
        self.capturedAt = capturedAt
    }

    public var idleAgents: [LiveAgent] { agents.filter { $0.state == .idle } }
    public var activeAgents: [LiveAgent] { agents.filter { $0.state != .idle } }

    /// The sentence the header leads with, because it is usually a surprise.
    public var headline: String? {
        guard !agents.isEmpty else { return nil }
        let idle = idleAgents.count
        let total = agents.count
        if idle == 0 { return "\(total) agent\(total == 1 ? "" : "s") running" }
        return "\(total) agent\(total == 1 ? "" : "s") running · \(idle) idle"
    }
}

public extension LiveState {
    /// What first run opens with — the same claim the old copy made, except
    /// measured on this machine instead of written into the view.
    ///
    /// Deliberately built from a process census rather than from a `LiveState`:
    /// the welcome step runs before the user has agreed to anything, and
    /// counting processes reads no transcript. Idle time is not claimed here
    /// because knowing it would mean opening the files consent is about.
    static func firstRunSummary(agents: Int, servers: Int) -> String {
        guard agents > 0 || servers > 0 else {
            return "No coding agents or local servers are running on this Mac right now. "
                + "When you start one, FlowTrace remembers where it got to."
        }

        var parts = ["You have"]
        if agents > 0 { parts.append(count(agents, "coding agent")) }
        if agents > 0 && servers > 0 { parts.append("and") }
        if servers > 0 { parts.append(count(servers, "local server")) }
        parts.append("running.")

        let question = agents > 0
            ? "Can you say what each one was doing?"
            : "Can you say what each one is for?"
        return parts.joined(separator: " ") + " " + question
    }

    /// "1 coding agent" / "11 coding agents".
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// How long something has been quiet, in the coarsest unit that is still
    /// true: minutes under an hour, then hours, then days.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "under a minute" }
        if seconds < 3600 { return count(Int(seconds / 60), "minute") }
        if seconds < 86_400 { return count(Int(seconds / 3600), "hour") }
        return count(Int(seconds / 86_400), "day")
    }
}
