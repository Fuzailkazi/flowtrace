import Foundation

/// A coding agent running on this machine right now.
public struct LiveAgent: Identifiable, Hashable, Sendable {
    /// How long ago the transcript was last written to, turned into a verdict.
    ///
    /// Four states rather than three because "idle" was doing two jobs. An
    /// agent quiet for two hours and one quiet for four days were the same
    /// word, so the genuinely forgotten work sat in a list next to work the
    /// user had merely stepped away from, and the list stopped being worth
    /// reading. See `ActivityThresholds` for the boundaries.
    public enum State: String, Sendable, CaseIterable {
        /// Something was written in the last couple of minutes.
        case working
        /// Recently active, and almost certainly sitting waiting for you.
        case waiting
        /// Quiet for a while. Probably deliberate — lunch, a meeting, another task.
        case quiet
        /// Quiet for long enough that you have very likely forgotten it is here.
        case forgotten

        /// Something is happening, or just happened.
        public var isActive: Bool { self == .working || self == .waiting }

        /// The word shown to the user.
        public var label: String {
            switch self {
            case .working: "working"
            case .waiting: "waiting"
            case .quiet: "quiet"
            case .forgotten: "forgotten"
            }
        }
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
    /// When the session file was last written. This is the agent's heartbeat,
    /// not yours.
    public var lastActivityAt: Date?
    /// When you last said something here.
    ///
    /// The distinction the product turns on. An agent left running unattended
    /// keeps `lastActivityAt` fresh forever, so judging attention by it means
    /// the work you actually walked away from never surfaces — which is the one
    /// thing FlowTrace exists to do.
    public var lastHumanActivityAt: Date?
    public var state: State
    public var sessionId: String?
    /// Your own note about this piece of work, if you've written one.
    public var note: String?

    /// Where this is running, and whether that counts as a project at all.
    /// Nil for agents built directly in tests.
    public var place: WorkPlace?

    /// False when the process is running but nothing on disk belongs to it, so
    /// its age is unknown rather than recent. Kept separate from the state
    /// because "waiting, activity unknown" and "waiting, wrote 40 seconds ago"
    /// are different claims and only one of them is measured.
    public var activityIsKnown: Bool = true

    /// True when FlowTrace found the process but has not been allowed to open
    /// its transcript. The row still says something honest — an agent is
    /// running here — without claiming to know what it is doing.
    public var transcriptHidden: Bool

    public init(
        pid: Int32, agent: AgentName, workingDirectory: String, projectRoot: String,
        repositoryName: String, branch: String? = nil, lastPrompt: String? = nil,
        lastActivityAt: Date? = nil, lastHumanActivityAt: Date? = nil,
        state: State, sessionId: String? = nil,
        note: String? = nil, transcriptHidden: Bool = false,
        place: WorkPlace? = nil, activityIsKnown: Bool = true
    ) {
        self.place = place
        self.activityIsKnown = activityIsKnown
        self.pid = pid
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.projectRoot = projectRoot
        self.repositoryName = repositoryName
        self.branch = branch
        self.lastPrompt = lastPrompt
        self.lastActivityAt = lastActivityAt
        self.lastHumanActivityAt = lastHumanActivityAt
        self.state = state
        self.sessionId = sessionId
        self.note = note
        self.transcriptHidden = transcriptHidden
    }

    /// How long you have been away, judged by what you said rather than by
    /// what the agent wrote.
    ///
    /// Falls back to the state the agent's heartbeat produced when no human
    /// turn could be dated — for OpenCode, whose store does not distinguish
    /// them, and for a session too long for the tail read to reach back into.
    /// Unknown is not the same as recent, but guessing old would be worse.
    public func attentionState(_ thresholds: ActivityThresholds = .default) -> State {
        guard let lastHumanActivityAt else { return state }
        return thresholds.state(forAge: Date().timeIntervalSince(lastHumanActivityAt))
    }

    /// True when the agent is still writing but you have not been here in a
    /// long time. The most valuable row on the screen and the one the old model
    /// could not express at all: it read as "working", because something was.
    public var isRunningUnattended: Bool {
        state.isActive && attentionState() == .forgotten
    }

    /// "19h ago", by the clock that matters.
    public var awayLabel: String? {
        guard let lastHumanActivityAt else { return nil }
        return LiveState.duration(Date().timeIntervalSince(lastHumanActivityAt))
    }

    public var idleFor: TimeInterval {
        guard let lastActivityAt else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(lastActivityAt)
    }

    /// "2m ago", "4d ago" — the honest signal, and usually the surprising one.
    public var lastActivityLabel: String {
        if transcriptHidden { return "not reading this one" }
        guard let lastActivityAt else {
            return activityIsKnown ? "unknown" : "running, no history yet"
        }
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

    /// Quiet long enough to be worth saying out loud. Hidden transcripts are
    /// excluded: nothing is known about them, and "forgotten" would really be
    /// a statement about permission.
    public var forgottenAgents: [LiveAgent] {
        // By attention, not by the agent's heartbeat — an agent left running
        // unattended for a fortnight belongs here however busy it looks.
        agents.filter { $0.attentionState() == .forgotten && !$0.transcriptHidden }
    }

    /// Running, but not anywhere that counts as a project. Reported as a count
    /// rather than as rows: the honest claim is "three agents are running
    /// outside your projects", not "you have a project called `/`".
    public var unplacedAgents: [LiveAgent] {
        agents.filter { $0.place?.isProject == false }
    }

    public var idleAgents: [LiveAgent] { agents.filter { !$0.state.isActive } }
    public var activeAgents: [LiveAgent] { agents.filter { $0.state.isActive } }

    /// The sentence the header leads with, because it is usually a surprise.
    public var headline: String? {
        guard !agents.isEmpty else { return nil }
        let total = agents.count
        let running = "\(total) agent\(total == 1 ? "" : "s") running"
        // The headline leads with what was forgotten, not with how many things
        // are idle: idle is a count, forgotten is a question.
        let forgotten = forgottenAgents.count
        if forgotten > 0 { return running + " · \(forgotten) forgotten" }
        let idle = idleAgents.count
        return idle == 0 ? running : running + " · \(idle) idle"
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
