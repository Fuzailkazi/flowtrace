import Foundation
import GRDB

/// An append-only record of what happened on a thread. Everything the user or
/// FlowTrace does to a thread lands here, which is what makes "what changed
/// since I last worked on it?" answerable.
public struct TimelineEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var workThreadId: String
    public var type: TimelineEventType
    public var title: String
    public var description: String
    /// Free-form detail keyed by the event type (e.g. captured URL, repo path).
    public var metadata: [String: String]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        workThreadId: String,
        type: TimelineEventType,
        title: String,
        description: String = "",
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workThreadId = workThreadId
        self.type = type
        self.title = title
        self.description = description
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

extension TimelineEvent: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "timelineEvent"

    public enum Columns {
        public static let id = Column("id")
        public static let workThreadId = Column("workThreadId")
        public static let createdAt = Column("createdAt")
    }
}
