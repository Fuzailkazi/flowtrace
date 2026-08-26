import Foundation
import GRDB

/// An intention or unfinished task. The primary object in FlowTrace — tabs,
/// repositories and agent sessions hang off a thread, never the other way round.
public struct WorkThread: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var description: String
    /// "Why am I doing this?"
    public var intent: String
    /// "What should I do next?"
    public var nextStep: String
    public var blocker: String?
    public var status: ThreadStatus
    public var priority: Priority
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastResumedAt: Date?

    /// Whether the user created this or FlowTrace proposed it. Detected threads
    /// still required an explicit confirmation before being written.
    public var origin: ThreadOrigin
    /// The raw evidence that justified a detected thread, so the user can always
    /// see what FlowTrace based its proposal on.
    public var detectionEvidence: DetectionEvidence?

    public init(
        id: String = UUID().uuidString,
        title: String,
        description: String = "",
        intent: String = "",
        nextStep: String = "",
        blocker: String? = nil,
        status: ThreadStatus = .active,
        priority: Priority = .medium,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastResumedAt: Date? = nil,
        origin: ThreadOrigin = .manual,
        detectionEvidence: DetectionEvidence? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.intent = intent
        self.nextStep = nextStep
        self.blocker = blocker
        self.status = status
        self.priority = priority
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastResumedAt = lastResumedAt
        self.origin = origin
        self.detectionEvidence = detectionEvidence
    }

    public var isBlocked: Bool {
        guard let blocker else { return false }
        return !blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Most recent meaningful moment on this thread, used for "Continue where you left off".
    public var lastActivityAt: Date {
        max(updatedAt, lastResumedAt ?? .distantPast)
    }
}

extension WorkThread: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "workThread"

    public enum Columns {
        public static let id = Column("id")
        public static let title = Column("title")
        public static let status = Column("status")
        public static let priority = Column("priority")
        public static let updatedAt = Column("updatedAt")
        public static let lastResumedAt = Column("lastResumedAt")
        public static let blocker = Column("blocker")
    }
}
