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
    public var screenshots: [ScreenshotExport]
}

public struct ScreenshotExport: Codable, Sendable {
    public let id: String
    public let importedAt: Date
    public let description: String
    public let ocrText: String
    public let ocrStatus: ScreenshotOCRStatus
    public let imageMIMEType: String
    public let thumbnailData: Data
    public let imageData: Data
}

extension Store {
    /// Everything FlowTrace holds, in a format the user can read and keep.
    ///
    /// The scan cache and dismissed proposals are deliberately excluded: they are
    /// derived state, not the user's own data.
    public func exportAll() throws -> ExportBundle {
        try database.writer.read { db in
            var bundle = try Self.exportBase(db)
            bundle.screenshots = try Row.fetchAll(db, sql: "SELECT * FROM screenshotMemory ORDER BY importedAt DESC, id DESC")
                .map(Self.exportScreenshot)
            return bundle
        }
    }

    private static func exportBase(_ db: Database) throws -> ExportBundle {
        ExportBundle(
            exportedAt: Date(),
            threads: try WorkThread.order(WorkThread.Columns.updatedAt.desc).fetchAll(db),
            browserContexts: try BrowserContext.fetchAll(db),
            codeContexts: try CodeContext.fetchAll(db),
            notes: try Note.fetchAll(db),
            timeline: try TimelineEvent.fetchAll(db),
            screenshots: []
        )
    }

    private static func exportScreenshot(_ row: Row) throws -> ScreenshotExport {
        let rawStatus: String = row["ocrStatus"]
        guard let status = ScreenshotOCRStatus(rawValue: rawStatus) else {
            throw ScreenshotStoreError.invalidOCRStatus
        }
        return ScreenshotExport(id: row["id"], importedAt: row["importedAt"],
            description: row["description"], ocrText: row["ocrText"], ocrStatus: status,
            imageMIMEType: row["imageMIMEType"], thumbnailData: row["thumbnailData"],
            imageData: row["imageData"])
    }

    /// Writes a point-in-time JSON export one screenshot at a time. The
    /// non-image records and one image plus its base64 encoding are in memory.
    public func exportJSON(to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".flowtrace-export-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            // One database read transaction gives the envelope and every image
            // the same point-in-time snapshot, even if another process writes.
            try database.writer.read { db in
                let base = try encoder.encode(Self.exportBase(db))
                let marker = Data("\"screenshots\":[]".utf8)
                guard let range = base.range(of: marker) else { throw ExportError.invalidEnvelope }
                try handle.write(contentsOf: base[..<range.lowerBound])
                try handle.write(contentsOf: Data("\"screenshots\":[".utf8))
                let cursor = try Row.fetchCursor(db, sql: "SELECT * FROM screenshotMemory ORDER BY importedAt DESC, id DESC")
                var first = true
                while let row = try cursor.next() {
                    if !first { try handle.write(contentsOf: Data(",".utf8)) }
                    first = false
                    try handle.write(contentsOf: encoder.encode(Self.exportScreenshot(row)))
                }
                try handle.write(contentsOf: Data("]".utf8))
                try handle.write(contentsOf: base[range.upperBound...])
            }
            try handle.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public enum ExportError: Error { case invalidEnvelope }

    public func exportJSON() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowtrace-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try exportJSON(to: url)
        return try Data(contentsOf: url)
    }

    /// A readable Markdown rendering, for keeping outside FlowTrace.
    public func exportMarkdown() throws -> String {
        let bundle = try database.writer.read { db in try Self.exportBase(db) }
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
        let count = try screenshotCount()
        if count > 0 {
            out += "## Screenshots\n\n"
            out += "Image bytes are included in the JSON export; this Markdown export contains text only.\n\n"
            for offset in stride(from: 0, to: count, by: 50) {
                for item in try screenshots(limit: 50, offset: offset) {
                    out += "### Screenshot \(item.id)\n\n"
                    out += "- **Imported:** \(formatter.string(from: item.importedAt))\n"
                    out += "- **Description:** \(item.description)\n"
                    out += "- **OCR status:** \(item.ocrStatus.rawValue)\n"
                    out += "- **Image type:** \(item.imageMIMEType)\n"
                    out += "- **Recognized text:** \(item.ocrText)\n\n"
                }
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
        // `DELETE` alone removes rows logically but can leave their old bytes
        // in free pages. Enable scrubbing before the deletes, including FTS
        // shadow-table writes, then rebuild and truncate the WAL afterward.
        try database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        try database.writer.write { db in
            for table in try Self.userTables(db) {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            // The FTS table is standalone, so emptying `workThread` leaves the
            // old text in `searchIndex_content`. `userTables` excludes the
            // shadow tables, and rightly — deleting from them directly errors —
            // so the virtual table is emptied through its own name.
            try db.execute(sql: "DELETE FROM searchIndex")
        }
        try database.writer.vacuum()
        _ = try database.writer.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
        // A log of what the app did with your data is part of what "delete
        // everything" has to mean.
        Diagnostics.clear()
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
        public var screenshots: Int
        /// Sessions FlowTrace has parsed and memoised so a rescan is fast. Held,
        /// so it is counted — it used to be invisible here and untouched by
        /// every delete control on the screen.
        public var parsedTranscripts: Int
        public var fileSizeBytes: Int64
        /// What the app wrote about itself. Not the user's data, so it does not
        /// make `isEmpty` false, but it is named so it can be got rid of.
        public var diagnosticsBytes: Int64

        public var isEmpty: Bool {
            writtenNotes + rawActivity + pagesVisited
                + agentSessions + projectNotes + screenshots + parsedTranscripts == 0
        }

        /// The log's size in the same shape as the database's.
        public var diagnosticsLabel: String {
            let kilobytes = Double(diagnosticsBytes) / 1024
            return kilobytes < 1024
                ? String(format: "%.0f KB", kilobytes)
                : String(format: "%.1f MB", kilobytes / 1024)
        }

        public var fileSizeLabel: String {
            let megabytes = Double(fileSizeBytes) / 1_048_576
            return megabytes < 1
                ? String(format: "%.0f KB", Double(fileSizeBytes) / 1024)
                : String(format: "%.1f MB", megabytes)
        }
    }

    public func holdings() throws -> Holdings {
        let size = Self.storedBytes()

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
                screenshots: try Int.fetchOne(db, sql: "SELECT count(*) FROM screenshotMemory") ?? 0,
                parsedTranscripts: try Int.fetchOne(db, sql:
                    "SELECT count(*) FROM scanCache") ?? 0,
                fileSizeBytes: size,
                diagnosticsBytes: Diagnostics.sizeInBytes()
            )
        }
    }

    /// How much disk FlowTrace is actually using.
    ///
    /// The database runs in WAL mode, so recent writes live in `-wal` until a
    /// checkpoint folds them back. Measuring only `flowtrace.sqlite` reported
    /// "4 KB" while a megabyte of real data sat beside it, which made the
    /// figure in Settings and the sidebar untrue at exactly the moment it
    /// mattered — just after writing something.
    public static func storedBytes(at url: URL = FlowTraceDatabase.defaultURL) -> Int64 {
        let manager = FileManager.default
        return [url.path, url.path + "-wal", url.path + "-shm"].reduce(into: Int64(0)) { total, path in
            guard let size = try? manager.attributesOfItem(atPath: path)[.size] as? Int64
            else { return }
            total += size
        }
    }

    /// Deletes everything recorded automatically, keeping everything you wrote.
    ///
    /// The distinction people actually want: erase the surveillance, keep the
    /// journal.
    /// Deletes everything recorded automatically, keeping everything you wrote.
    ///
    /// "Recorded automatically" is wider than the activity table: the scan memo
    /// holds parsed sessions, pending proposals hold prompts read out of them,
    /// and the diagnostics log holds what the app saw itself doing. A button
    /// that said it erased what was recorded automatically and left three of
    /// those behind was not telling the truth.
    ///
    /// Accepted and dismissed proposals stay: those carry a decision you made.
    @discardableResult
    public func deleteRawActivity() throws -> Int {
        let erased = try database.writer.write { db -> Int in
            try db.execute(sql: """
                DELETE FROM activityEvent
                WHERE (note IS NULL OR note = '') AND kind != 'agentSession'
                """)
            // Captured immediately: `changesCount` reports only the most recent
            // statement, so reading it after the deletes below would report the
            // proposal count in a toast that says "removed N automatic records".
            let count = db.changesCount
            try db.execute(sql: "DELETE FROM scanCache")
            try db.execute(sql: "DELETE FROM threadProposal WHERE state = 'pending'")
            return count
        }
        Diagnostics.clear()
        return erased
    }
}
