import Foundation

/// Exactly what FlowTrace observed on disk to justify proposing a thread.
///
/// This is stored verbatim and surfaced in the UI. The product principle is that
/// trust matters more than automation: the user must always be able to see why
/// something was proposed, without taking FlowTrace's word for it.
public struct DetectionEvidence: Codable, Hashable, Sendable {
    public var repositoryPath: String
    public var repositoryName: String
    public var branch: String
    /// Number of uncommitted files at scan time.
    public var dirtyFileCount: Int
    /// Whole days since the most recent commit.
    public var daysSinceLastCommit: Int
    /// Commits on this branch not present on its upstream, if there is one.
    public var unpushedCommitCount: Int
    /// How many agent sessions referenced this repository.
    public var sessionCount: Int
    public var agents: [AgentName]
    /// The last thing the user asked an agent to do here — verbatim, truncated.
    public var lastPrompt: String?
    public var lastSessionAt: Date?
    public var scoredAt: Date

    public init(
        repositoryPath: String,
        repositoryName: String,
        branch: String,
        dirtyFileCount: Int,
        daysSinceLastCommit: Int,
        unpushedCommitCount: Int,
        sessionCount: Int,
        agents: [AgentName],
        lastPrompt: String? = nil,
        lastSessionAt: Date? = nil,
        scoredAt: Date = Date()
    ) {
        self.repositoryPath = repositoryPath
        self.repositoryName = repositoryName
        self.branch = branch
        self.dirtyFileCount = dirtyFileCount
        self.daysSinceLastCommit = daysSinceLastCommit
        self.unpushedCommitCount = unpushedCommitCount
        self.sessionCount = sessionCount
        self.agents = agents
        self.lastPrompt = lastPrompt
        self.lastSessionAt = lastSessionAt
        self.scoredAt = scoredAt
    }

    /// Human-readable justification lines, one per observed signal. Rendered
    /// directly on proposal cards and in the thread timeline.
    public var reasons: [String] {
        var out: [String] = []
        if dirtyFileCount > 0 {
            out.append("\(dirtyFileCount) uncommitted file\(dirtyFileCount == 1 ? "" : "s")")
        }
        if unpushedCommitCount > 0 {
            out.append("\(unpushedCommitCount) unpushed commit\(unpushedCommitCount == 1 ? "" : "s")")
        }
        if daysSinceLastCommit > 0 {
            out.append("last commit \(daysSinceLastCommit)d ago")
        }
        if sessionCount > 0 {
            let names = agents.map(\.label).joined(separator: " + ")
            out.append("\(sessionCount) \(names) session\(sessionCount == 1 ? "" : "s")")
        }
        return out
    }
}
