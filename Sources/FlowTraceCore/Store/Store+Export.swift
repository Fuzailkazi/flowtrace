import Foundation
import GRDB

/// The complete contents of the database, for export.
public struct ExportBundle: Codable, Sendable {
    public var exportedAt: Date
    public var threads: [WorkThread]
    public var browserContexts: [BrowserContext]
    public var codeContexts: [CodeContext]
    public var notes: [Note]
    public var timeline: [TimelineEvent]
}

extension Store {
    /// Everything FlowTrace holds, in a format the user can read and keep.
    ///
    /// The scan cache and dismissed proposals are deliberately excluded: they are
    /// derived state, not the user's own data.
    public func exportAll() throws -> ExportBundle {
        try database.writer.read { db in
            ExportBundle(
                exportedAt: Date(),
                threads: try WorkThread.order(WorkThread.Columns.updatedAt.desc).fetchAll(db),
                browserContexts: try BrowserContext.fetchAll(db),
                codeContexts: try CodeContext.fetchAll(db),
                notes: try Note.fetchAll(db),
                timeline: try TimelineEvent.fetchAll(db)
            )
        }
    }

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exportAll())
    }

    /// A readable Markdown rendering, for keeping outside FlowTrace.
    public func exportMarkdown() throws -> String {
        let bundle = try exportAll()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        var out = "# FlowTrace export\n\n_\(formatter.string(from: bundle.exportedAt))_\n\n"

        for thread in bundle.threads {
            out += "## \(thread.title)\n\n"
            out += "- **Status:** \(thread.status.label) · **Priority:** \(thread.priority.label)\n"
            if !thread.intent.isEmpty { out += "- **Why:** \(thread.intent)\n" }
            if !thread.nextStep.isEmpty { out += "- **Next step:** \(thread.nextStep)\n" }
            if let blocker = thread.blocker, !blocker.isEmpty { out += "- **Blocked by:** \(blocker)\n" }
            if !thread.tags.isEmpty { out += "- **Tags:** \(thread.tags.joined(separator: ", "))\n" }
            out += "- **Created:** \(formatter.string(from: thread.createdAt))\n\n"

            let repositories = bundle.codeContexts.filter { $0.workThreadId == thread.id }
            if !repositories.isEmpty {
                out += "### Repositories\n\n"
                for context in repositories {
                    out += "- `\(context.repositoryPath)`"
                    if let branch = context.branch { out += " · \(branch)" }
                    if let agent = context.agentName { out += " · \(agent.label)" }
                    if !context.note.isEmpty { out += " — \(context.note)" }
                    out += "\n"
                }
                out += "\n"
            }

            let tabs = bundle.browserContexts.filter { $0.workThreadId == thread.id }
            if !tabs.isEmpty {
                out += "### Tabs\n\n"
                for tab in tabs {
                    out += "- [\(tab.pageTitle)](\(tab.url))"
                    if !tab.note.isEmpty { out += " — \(tab.note)" }
                    out += "\n"
                }
                out += "\n"
            }

            let notes = bundle.notes.filter { $0.workThreadId == thread.id }
            if !notes.isEmpty {
                out += "### Notes\n\n"
                for note in notes {
                    out += "- \(note.isDecision ? "**Decision:** " : "")\(note.content)\n"
                }
                out += "\n"
            }
        }
        return out
    }

    /// Removes everything.
    ///
    /// The table list is read from the database rather than written out here. It
    /// used to be a literal, and three tables added later — every app you used,
    /// every window title, every page you visited, and every note you wrote —
    /// were silently left behind by a button labelled "Delete all data". A list
    /// that has to be remembered is a list that will be forgotten.
    public func deleteAllData() throws {
        try database.writer.write { db in
            for table in try Self.userTables(db) {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    /// Every table FlowTrace owns: no migration bookkeeping, and no FTS shadow
    /// tables, which are maintained by their parent and error on direct delete.
    static func userTables(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%'
              AND name NOT LIKE 'grdb_%'
              AND name NOT LIKE '%_content'
              AND name NOT LIKE '%_data'
              AND name NOT LIKE '%_idx'
              AND name NOT LIKE '%_docsize'
              AND name NOT LIKE '%_config'
            """)
    }

    /// Clears the scan memo so the next scan re-reads every session file.
    public func clearScanCache() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM scanCache")
        }
    }

    public func counts() throws -> [String: Int] {
        try database.writer.read { db in
            [
                "threads": try WorkThread.fetchCount(db),
                "tabs": try BrowserContext.fetchCount(db),
                "repositories": try CodeContext.fetchCount(db),
                "notes": try Note.fetchCount(db),
                "events": try TimelineEvent.fetchCount(db),
                "proposals": try ThreadProposal.fetchCount(db),
            ]
        }
    }

    /// What FlowTrace is holding, in the terms the user thinks in rather than in
    /// table names. Shown in Settings so the delete controls have something
    /// concrete to act on.
    public struct Holdings: Sendable {
        public var writtenNotes: Int
        public var rawActivity: Int
        public var pagesVisited: Int
        public var agentSessions: Int
        public var projectNotes: Int
        public var fileSizeBytes: Int64

        public var isEmpty: Bool {
            writtenNotes + rawActivity + pagesVisited + agentSessions + projectNotes == 0
        }

        public var fileSizeLabel: String {
            let megabytes = Double(fileSizeBytes) / 1_048_576
            return megabytes < 1
                ? String(format: "%.0f KB", Double(fileSizeBytes) / 1024)
                : String(format: "%.1f MB", megabytes)
        }
    }

    public func holdings() throws -> Holdings {
        let size = (try? FileManager.default.attributesOfItem(
            atPath: FlowTraceDatabase.defaultURL.path
        )[.size] as? Int64) ?? 0

        return try database.writer.read { db in
            Holdings(
                writtenNotes: try Int.fetchOne(db, sql:
                    "SELECT count(*) FROM activityEvent WHERE note IS NOT NULL AND note != ''") ?? 0,
                rawActivity: try Int.fetchOne(db, sql:
                    "SELECT count(*) FROM activityEvent WHERE note IS NULL OR note = ''") ?? 0,
                pagesVisited: try Int.fetchOne(db, sql:
                    "SELECT count(DISTINCT url) FROM activityEvent WHERE url IS NOT NULL") ?? 0,
                agentSessions: try Int.fetchOne(db, sql:
                    "SELECT count(*) FROM activityEvent WHERE kind = 'agentSession'") ?? 0,
                projectNotes: try ProjectNote.fetchCount(db),
                fileSizeBytes: size ?? 0
            )
        }
    }

    /// Deletes everything recorded automatically, keeping everything you wrote.
    ///
    /// The distinction people actually want: erase the surveillance, keep the
    /// journal.
    @discardableResult
    public func deleteRawActivity() throws -> Int {
        try database.writer.write { db in
            try db.execute(sql: """
                DELETE FROM activityEvent
                WHERE (note IS NULL OR note = '') AND kind != 'agentSession'
                """)
            return db.changesCount
        }
    }
}
