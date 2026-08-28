import Foundation
import GRDB

/// Reading and writing the day.
///
/// The whole timeline is one query — a day, in order — so this stays small on
/// purpose. The interesting logic is coalescing, not storage.
extension Store {
    /// How long a gap breaks a span. Step away for two minutes and come back and
    /// it is the same sitting; twenty minutes later it is a new one.
    static let activityMergeGap: TimeInterval = 5 * 60

    /// Records that you are now in something, closing whatever came before.
    ///
    /// If this is the same activity as the open span, nothing new is written —
    /// the span simply continues. That single rule is what keeps a day of
    /// alt-tabbing from becoming an unreadable list.
    @discardableResult
    public func beginActivity(_ event: ActivityEvent) throws -> ActivityEvent {
        try database.writer.write { db in
            let open = try ActivityEvent
                .filter(ActivityEvent.Columns.endedAt == nil)
                .order(ActivityEvent.Columns.startedAt.desc)
                .fetchOne(db)

            if let open {
                // Same thing as before — you never left, so don't split the span.
                if open.describesSameActivity(as: event) { return open }

                var closing = open
                closing.endedAt = event.startedAt
                try closing.update(db)

                // Returning to the same thing after a short gap resumes the old
                // span instead of starting a new line for it.
                //
                // The span just closed above is excluded: it is now the most
                // recently ended row, and without this the lookup only ever finds
                // the thing you just left rather than the thing you came back to.
                if let previous = try ActivityEvent
                    .filter(ActivityEvent.Columns.endedAt != nil)
                    .filter(ActivityEvent.Columns.id != closing.id)
                    .order(ActivityEvent.Columns.endedAt.desc)
                    .fetchOne(db),
                   previous.describesSameActivity(as: event),
                   let previousEnd = previous.endedAt,
                   event.startedAt.timeIntervalSince(previousEnd) < Self.activityMergeGap {
                    var resumed = previous
                    resumed.endedAt = nil
                    try resumed.update(db)
                    return resumed
                }
            }

            var event = event
            try event.insert(db)
            return event
        }
    }

    /// Closes the currently open span — on quit, or when the machine sleeps.
    public func endOpenActivity(at date: Date = Date()) throws {
        try database.writer.write { db in
            guard var open = try ActivityEvent
                .filter(ActivityEvent.Columns.endedAt == nil)
                .order(ActivityEvent.Columns.startedAt.desc)
                .fetchOne(db)
            else { return }
            open.endedAt = date
            try open.update(db)
        }
    }

    /// Inserts an event that already knows its own span — an agent session read
    /// from a transcript, or a git action. These don't participate in coalescing
    /// because they didn't happen "now".
    @discardableResult
    public func recordActivity(_ event: ActivityEvent) throws -> ActivityEvent {
        var event = event
        try database.writer.write { db in try event.insert(db) }
        return event
    }

    /// One day of things *you wrote* — the timeline's only query.
    ///
    /// Ambient capture is still recorded, but it is context, not content. Left to
    /// fill the timeline it produced 24 entries in a day of which 2 said anything:
    /// "Code" seven times over, "Brave Browser" five, indistinguishable from each
    /// other and worth nothing to read. What earns a line is a sentence you chose
    /// to write.
    ///
    /// Pass `includingAmbient` to see the raw record underneath.
    public func activity(
        on day: Date,
        minimumSeconds: TimeInterval = 20,
        includingAmbient: Bool = false
    ) throws -> [ActivityEvent] {
        let all = try allActivity(on: day, minimumSeconds: minimumSeconds)
        guard !includingAmbient else { return all }
        return all.filter { !$0.isUnexplained }
    }

    /// Everything recorded on a day, annotated or not. Used for the "just before
    /// this" context in the capture panel, and by the raw view.
    public func allActivity(
        on day: Date, minimumSeconds: TimeInterval = 20
    ) throws -> [ActivityEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        return try database.writer.read { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.startedAt >= start)
                .filter(ActivityEvent.Columns.startedAt < end)
                .order(ActivityEvent.Columns.startedAt.asc)
                .fetchAll(db)
        }
        // A half-second glance at a window is not something you were doing. Keep
        // anything annotated regardless — if you wrote about it, it mattered.
        .filter { $0.duration >= minimumSeconds || !$0.isUnexplained || $0.kind != .app }
    }

    /// Days that have anything on them, newest first — for moving between days.
    public func daysWithActivity(limit: Int = 30) throws -> [Date] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT date(startedAt) AS day
                FROM activityEvent
                ORDER BY day DESC
                LIMIT ?
                """, arguments: [limit])
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            return rows.compactMap { formatter.date(from: $0["day"]) }
        }
    }

    /// Writes your reason onto an event. This is the point of the whole app.
    @discardableResult
    public func annotate(activityId: String, note: String) throws -> ActivityEvent? {
        try database.writer.write { db in
            guard var event = try ActivityEvent.fetchOne(db, key: activityId) else { return nil }
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            event.note = trimmed.isEmpty ? nil : trimmed
            event.noteAt = trimmed.isEmpty ? nil : Date()
            try event.update(db)
            return event
        }
    }

    /// Ambient events are only useful while they are recent — they exist to give
    /// the capture panel something to say about what led here. Anything older,
    /// and unwritten-on, is noise taking up space.
    @discardableResult
    public func pruneAmbientActivity(olderThan days: Int = 2) throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return try database.writer.write { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.startedAt < cutoff)
                .filter(ActivityEvent.Columns.note == nil)
                .filter(ActivityEvent.Columns.kind != ActivityKind.agentSession.rawValue)
                .deleteAll(db)
        }
    }

    public func deleteActivity(id: String) throws {
        _ = try database.writer.write { db in
            try ActivityEvent.deleteOne(db, key: id)
        }
    }

    /// Removes a whole day. The delete control that makes ambient capture
    /// acceptable to live with.
    public func deleteActivity(on day: Date) throws {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        _ = try database.writer.write { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.startedAt >= start)
                .filter(ActivityEvent.Columns.startedAt < end)
                .deleteAll(db)
        }
    }
}

extension Store {
    /// Inserts or refreshes an imported event, keyed on its external identity.
    ///
    /// The user's own note is never overwritten by a re-import — the machine may
    /// revise what it observed, but what you wrote is yours.
    @discardableResult
    public func upsertImportedActivity(_ event: ActivityEvent) throws -> ActivityEvent {
        guard let externalId = event.externalId else { return try recordActivity(event) }

        return try database.writer.write { db in
            if var existing = try ActivityEvent
                .filter(ActivityEvent.Columns.externalId == externalId)
                .fetchOne(db) {
                existing.startedAt = event.startedAt
                existing.endedAt = event.endedAt
                existing.appName = event.appName
                existing.target = event.target
                existing.metadata = event.metadata
                try existing.update(db)
                return existing
            }
            var fresh = event
            try fresh.insert(db)
            return fresh
        }
    }
}

extension Store {
    /// The span you are inside right now, if any.
    public func openActivity() throws -> ActivityEvent? {
        try database.writer.read { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.endedAt == nil)
                .order(ActivityEvent.Columns.startedAt.desc)
                .fetchOne(db)
        }
    }

    /// What was happening just before a moment — the few entries that give a
    /// stray tab its context.
    public func activityLeadingUp(
        to moment: Date, within minutes: Double = 20, limit: Int = 3
    ) throws -> [ActivityEvent] {
        let from = moment.addingTimeInterval(-minutes * 60)
        return try database.writer.read { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.startedAt >= from)
                .filter(ActivityEvent.Columns.startedAt < moment)
                .order(ActivityEvent.Columns.startedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}
