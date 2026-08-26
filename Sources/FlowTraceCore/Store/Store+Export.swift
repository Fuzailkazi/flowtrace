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

    /// Removes everything. Used by the delete-all control in Settings.
    public func deleteAllData() throws {
        try database.writer.write { db in
            for table in ["searchIndex", "timelineEvent", "note", "browserContext",
                          "codeContext", "workThread", "threadProposal",
                          "repoSnapshot", "scanCache", "ignoredPath"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
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
}
