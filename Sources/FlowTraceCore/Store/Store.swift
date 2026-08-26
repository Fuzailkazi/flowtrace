import Foundation
import GRDB

/// The single typed entry point to FlowTrace's data.
///
/// Both the app and the CLI go through this type. Every mutation that matters
/// also writes a `TimelineEvent` and keeps the search index in step, so those
/// two things can never drift from the records they describe.
public final class Store {
    public let database: FlowTraceDatabase
    private var writer: DatabaseWriter { database.writer }

    public init(database: FlowTraceDatabase) {
        self.database = database
    }

    public convenience init(url: URL = FlowTraceDatabase.defaultURL) throws {
        try self.init(database: FlowTraceDatabase(url: url))
    }

    // MARK: - Threads

    public func allThreads() throws -> [WorkThread] {
        try writer.read { db in
            try WorkThread.order(WorkThread.Columns.updatedAt.desc).fetchAll(db)
        }
    }

    public func threads(status: ThreadStatus) throws -> [WorkThread] {
        try writer.read { db in
            try WorkThread
                .filter(WorkThread.Columns.status == status.rawValue)
                .order(WorkThread.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    public func thread(id: String) throws -> WorkThread? {
        try writer.read { db in try WorkThread.fetchOne(db, key: id) }
    }

    /// Creates a thread and opens its timeline.
    @discardableResult
    public func create(_ thread: WorkThread) throws -> WorkThread {
        var thread = thread
        thread.updatedAt = Date()
        return try writer.write { db in
            try thread.insert(db)
            try Self.reindex(db, thread: thread)
            try Self.record(
                db,
                TimelineEvent(
                    workThreadId: thread.id,
                    type: thread.origin == .detected ? .detected : .created,
                    title: thread.origin == .detected
                        ? "Detected from unfinished work"
                        : "Thread created",
                    description: thread.intent,
                    metadata: thread.detectionEvidence.map {
                        ["repository": $0.repositoryPath, "branch": $0.branch]
                    } ?? [:]
                )
            )
            return thread
        }
    }

    /// Persists edits, refreshes `updatedAt`, and records what changed.
    @discardableResult
    public func update(_ thread: WorkThread) throws -> WorkThread {
        var updated = thread
        updated.updatedAt = Date()
        return try writer.write { db in
            let previous = try WorkThread.fetchOne(db, key: thread.id)
            try updated.update(db)
            try Self.reindex(db, thread: updated)

            if let previous {
                for event in Self.diffEvents(from: previous, to: updated) {
                    try Self.record(db, event)
                }
            }
            return updated
        }
    }

    public func delete(threadId: String) throws {
        _ = try writer.write { db in
            try SearchIndex.removeAll(db, threadId: threadId)
            return try WorkThread.deleteOne(db, key: threadId)
        }
    }

    /// Marks a thread as picked back up. This is what "Resume" writes.
    @discardableResult
    public func resume(threadId: String) throws -> WorkThread? {
        try writer.write { db in
            guard var thread = try WorkThread.fetchOne(db, key: threadId) else { return nil }
            let now = Date()
            thread.lastResumedAt = now
            thread.updatedAt = now
            if thread.status == .paused { thread.status = .active }
            try thread.update(db)
            try Self.reindex(db, thread: thread)
            try Self.record(db, TimelineEvent(
                workThreadId: threadId,
                type: .resumed,
                title: "Resumed",
                description: thread.nextStep
            ))
            return thread
        }
    }

    @discardableResult
    public func setStatus(_ status: ThreadStatus, threadId: String) throws -> WorkThread? {
        try writer.write { db in
            guard var thread = try WorkThread.fetchOne(db, key: threadId) else { return nil }
            guard thread.status != status else { return thread }
            let wasCompleted = thread.status == .completed
            thread.status = status
            thread.updatedAt = Date()
            try thread.update(db)
            try Self.reindex(db, thread: thread)

            let type: TimelineEventType = switch status {
            case .paused: .paused
            case .completed: .completed
            case .active: wasCompleted ? .reopened : .resumed
            }
            try Self.record(db, TimelineEvent(
                workThreadId: threadId,
                type: type,
                title: "Marked \(status.label.lowercased())"
            ))
            return thread
        }
    }

    // MARK: - Timeline & search sync

    static func record(_ db: Database, _ event: TimelineEvent) throws {
        var event = event
        try event.insert(db)
    }

    static func reindex(_ db: Database, thread: WorkThread) throws {
        var parts = [thread.description, thread.intent, thread.nextStep]
        if let blocker = thread.blocker { parts.append("blocked \(blocker)") }
        parts.append(contentsOf: thread.tags)
        parts.append(thread.status.rawValue)
        try SearchIndex.index(
            db,
            kind: .thread,
            recordId: thread.id,
            threadId: thread.id,
            title: thread.title,
            body: parts.filter { !$0.isEmpty }.joined(separator: " \n ")
        )
    }

    /// Turns an edit into the specific timeline entries worth remembering.
    /// Only fields that carry intent are tracked — not every keystroke.
    static func diffEvents(from old: WorkThread, to new: WorkThread) -> [TimelineEvent] {
        var events: [TimelineEvent] = []

        if old.nextStep != new.nextStep, !new.nextStep.isEmpty {
            events.append(TimelineEvent(
                workThreadId: new.id, type: .nextStepUpdated,
                title: "Next step updated", description: new.nextStep
            ))
        }
        if old.intent != new.intent, !new.intent.isEmpty {
            events.append(TimelineEvent(
                workThreadId: new.id, type: .intentUpdated,
                title: "Intent updated", description: new.intent
            ))
        }
        if old.blocker != new.blocker {
            if new.isBlocked {
                events.append(TimelineEvent(
                    workThreadId: new.id, type: .blockerSet,
                    title: "Blocked", description: new.blocker ?? ""
                ))
            } else if old.isBlocked {
                events.append(TimelineEvent(
                    workThreadId: new.id, type: .blockerCleared,
                    title: "Blocker cleared", description: old.blocker ?? ""
                ))
            }
        }
        if old.status != new.status {
            let type: TimelineEventType = switch new.status {
            case .paused: .paused
            case .completed: .completed
            case .active: old.status == .completed ? .reopened : .resumed
            }
            events.append(TimelineEvent(
                workThreadId: new.id, type: type,
                title: "Marked \(new.status.label.lowercased())"
            ))
        }
        return events
    }

    public func timeline(threadId: String) throws -> [TimelineEvent] {
        try writer.read { db in
            try TimelineEvent
                .filter(TimelineEvent.Columns.workThreadId == threadId)
                .order(TimelineEvent.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    // MARK: - Search

    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        try writer.read { db in try SearchIndex.search(db, query: query, limit: limit) }
    }
}
