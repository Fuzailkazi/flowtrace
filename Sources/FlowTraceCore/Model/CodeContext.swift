import Foundation
import GRDB

/// A repository, terminal or coding-agent session attached to a thread.
public struct CodeContext: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var workThreadId: String?
    public var agentName: AgentName?
    public var repositoryName: String
    public var repositoryPath: String
    public var branch: String?
    public var latestCommit: String?
    public var note: String
    public var nextStep: String
    public var capturedAt: Date

    /// Git state at capture time. Compared against a later probe to answer
    /// "what changed since I last worked on it?".
    public var dirtyFileCount: Int
    public var lastCommitAt: Date?
    public var commitsAhead: Int
    public var commitsBehind: Int

    /// Set when this context came from a discovered agent session rather than a
    /// folder picker, so the session can be reopened later.
    public var agentSessionId: String?
    public var agentSessionPath: String?

    public init(
        id: String = UUID().uuidString,
        workThreadId: String? = nil,
        agentName: AgentName? = nil,
        repositoryName: String,
        repositoryPath: String,
        branch: String? = nil,
        latestCommit: String? = nil,
        note: String = "",
        nextStep: String = "",
        capturedAt: Date = Date(),
        dirtyFileCount: Int = 0,
        lastCommitAt: Date? = nil,
        commitsAhead: Int = 0,
        commitsBehind: Int = 0,
        agentSessionId: String? = nil,
        agentSessionPath: String? = nil
    ) {
        self.id = id
        self.workThreadId = workThreadId
        self.agentName = agentName
        self.repositoryName = repositoryName
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.latestCommit = latestCommit
        self.note = note
        self.nextStep = nextStep
        self.capturedAt = capturedAt
        self.dirtyFileCount = dirtyFileCount
        self.lastCommitAt = lastCommitAt
        self.commitsAhead = commitsAhead
        self.commitsBehind = commitsBehind
        self.agentSessionId = agentSessionId
        self.agentSessionPath = agentSessionPath
    }

    public var shortCommit: String? {
        latestCommit.map { String($0.prefix(7)) }
    }

    /// Path with the home directory abbreviated, for display.
    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return repositoryPath.hasPrefix(home)
            ? "~" + repositoryPath.dropFirst(home.count)
            : repositoryPath
    }
}

extension CodeContext: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "codeContext"

    public enum Columns {
        public static let id = Column("id")
        public static let workThreadId = Column("workThreadId")
        public static let repositoryPath = Column("repositoryPath")
        public static let capturedAt = Column("capturedAt")
    }
}
