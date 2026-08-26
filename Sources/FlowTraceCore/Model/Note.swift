import Foundation
import GRDB

/// A note or a recorded decision on a thread. Decisions are notes flagged as
/// such so the detail view can list them separately.
public struct Note: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var workThreadId: String
    public var content: String
    public var isDecision: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        workThreadId: String,
        content: String,
        isDecision: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workThreadId = workThreadId
        self.content = content
        self.isDecision = isDecision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Note: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note"

    public enum Columns {
        public static let id = Column("id")
        public static let workThreadId = Column("workThreadId")
        public static let createdAt = Column("createdAt")
        public static let isDecision = Column("isDecision")
    }
}
