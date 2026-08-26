import Foundation

/// One coding-agent session as FlowTrace found it on disk.
///
/// Everything here is read from files the agent already wrote. FlowTrace never
/// attaches to a running agent, injects anything, or modifies these files.
public struct AgentSession: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentName
    /// Working directory the session ran in — the link back to a repository.
    public var cwd: String?
    public var branch: String?
    /// Title the agent generated for the session, when it wrote one.
    public var title: String?
    public var firstPrompt: String?
    public var lastPrompt: String?
    /// The last prompt that actually said something. "do it" is a real last
    /// prompt but a useless next step, so the two are tracked separately.
    public var lastSubstantivePrompt: String?
    public var startedAt: Date?
    public var lastActivityAt: Date?
    public var filePath: String
    public var messageCount: Int

    public init(
        id: String,
        agent: AgentName,
        cwd: String? = nil,
        branch: String? = nil,
        title: String? = nil,
        firstPrompt: String? = nil,
        lastPrompt: String? = nil,
        lastSubstantivePrompt: String? = nil,
        startedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        filePath: String,
        messageCount: Int = 0
    ) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.branch = branch
        self.title = title
        self.firstPrompt = firstPrompt
        self.lastPrompt = lastPrompt
        self.lastSubstantivePrompt = lastSubstantivePrompt
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.filePath = filePath
        self.messageCount = messageCount
    }

    /// Best available human label for this session.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let firstPrompt, !firstPrompt.isEmpty { return Self.condense(firstPrompt) }
        return "\(agent.label) session"
    }

    /// The most useful "what were you in the middle of" line available.
    public var resumePrompt: String? { lastSubstantivePrompt ?? lastPrompt }

    /// Bare acknowledgements carry no instruction, so they never become a
    /// thread's next step.
    static let acknowledgements: Set<String> = [
        "do it", "yes", "y", "ok", "okay", "go", "go on", "go ahead", "continue",
        "proceed", "sure", "yep", "yeah", "next", "thanks", "thank you", "done",
        "fix it", "try again", "again", "no", "n", "stop", "k", "please",
    ]

    public static func isSubstantive(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if acknowledgements.contains(normalized) { return false }
        return normalized.count >= 15
    }

    /// Collapse a prompt to one short line suitable for a title.
    static func condense(_ text: String, limit: Int = 72) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}

/// A source of agent sessions. New agents are added by implementing this and
/// registering the adapter — nothing else in FlowTrace needs to change.
public protocol AgentAdapter: Sendable {
    var agent: AgentName { get }
    /// Directories this adapter reads. Shown verbatim on the consent screen so
    /// the user can see exactly what will be touched before anything is scanned.
    var searchPaths: [String] { get }
    /// Whether those directories exist on this machine.
    var isAvailable: Bool { get }
    func discoverSessions(cache: SessionCache?) throws -> [AgentSession]
}

public extension AgentAdapter {
    var isAvailable: Bool {
        searchPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
}

/// Memo across scans, so only files that actually changed get re-parsed.
public protocol SessionCache: AnyObject {
    func cached(path: String, size: Int64, modifiedAt: Date) -> AgentSession?
    func store(_ session: AgentSession, path: String, size: Int64, modifiedAt: Date)
}
