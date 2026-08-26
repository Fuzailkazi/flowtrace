import Foundation
import GRDB

/// Unfinished work FlowTrace found on disk and is offering to turn into a thread.
///
/// A proposal is never silently promoted. It sits here until the user accepts it
/// (which creates a real `WorkThread`) or dismisses it (which suppresses it on
/// future scans).
public struct ThreadProposal: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// Stable identity across rescans: repository path + branch.
    public var repositoryPath: String
    public var branch: String
    public var suggestedTitle: String
    public var suggestedIntent: String
    public var suggestedNextStep: String
    /// Higher means more likely to be genuinely abandoned. See `AbandonedWorkDetector`.
    public var score: Double
    public var evidence: DetectionEvidence
    public var state: ProposalState
    /// Set once accepted, so the proposal can point at the thread it became.
    public var acceptedThreadId: String?
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public init(
        id: String = UUID().uuidString,
        repositoryPath: String,
        branch: String,
        suggestedTitle: String,
        suggestedIntent: String = "",
        suggestedNextStep: String = "",
        score: Double,
        evidence: DetectionEvidence,
        state: ProposalState = .pending,
        acceptedThreadId: String? = nil,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.suggestedTitle = suggestedTitle
        self.suggestedIntent = suggestedIntent
        self.suggestedNextStep = suggestedNextStep
        self.score = score
        self.evidence = evidence
        self.state = state
        self.acceptedThreadId = acceptedThreadId
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    /// Identity used to match a freshly scored proposal against a stored one.
    public var dedupeKey: String { "\(repositoryPath)#\(branch)" }
}

extension ThreadProposal: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "threadProposal"

    public enum Columns {
        public static let id = Column("id")
        public static let repositoryPath = Column("repositoryPath")
        public static let branch = Column("branch")
        public static let state = Column("state")
        public static let score = Column("score")
    }
}
