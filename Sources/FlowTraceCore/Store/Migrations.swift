import Foundation
import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.schema") { db in
            try db.create(table: "workThread") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("intent", .text).notNull().defaults(to: "")
                t.column("nextStep", .text).notNull().defaults(to: "")
                t.column("blocker", .text)
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("priority", .text).notNull().defaults(to: "medium")
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastResumedAt", .datetime)
                t.column("origin", .text).notNull().defaults(to: "manual")
                t.column("detectionEvidence", .text)
            }
            try db.create(index: "idx_thread_status", on: "workThread", columns: ["status", "updatedAt"])

            try db.create(table: "browserContext") { t in
                t.primaryKey("id", .text)
                t.belongsTo("workThread", onDelete: .cascade)
                t.column("browser", .text).notNull()
                t.column("windowTitle", .text)
                t.column("pageTitle", .text).notNull()
                t.column("url", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("capturedAt", .datetime).notNull()
            }
            try db.create(index: "idx_tab_captured", on: "browserContext", columns: ["capturedAt"])

            try db.create(table: "codeContext") { t in
                t.primaryKey("id", .text)
                t.belongsTo("workThread", onDelete: .cascade)
                t.column("agentName", .text)
                t.column("repositoryName", .text).notNull()
                t.column("repositoryPath", .text).notNull()
                t.column("branch", .text)
                t.column("latestCommit", .text)
                t.column("note", .text).notNull().defaults(to: "")
                t.column("nextStep", .text).notNull().defaults(to: "")
                t.column("capturedAt", .datetime).notNull()
                t.column("dirtyFileCount", .integer).notNull().defaults(to: 0)
                t.column("lastCommitAt", .datetime)
                t.column("commitsAhead", .integer).notNull().defaults(to: 0)
                t.column("commitsBehind", .integer).notNull().defaults(to: 0)
                t.column("agentSessionId", .text)
                t.column("agentSessionPath", .text)
            }
            try db.create(index: "idx_code_captured", on: "codeContext", columns: ["capturedAt"])

            try db.create(table: "timelineEvent") { t in
                t.primaryKey("id", .text)
                t.belongsTo("workThread", onDelete: .cascade).notNull()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("metadata", .text).notNull().defaults(to: "{}")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_event_thread", on: "timelineEvent", columns: ["workThreadId", "createdAt"])

            try db.create(table: "note") { t in
                t.primaryKey("id", .text)
                t.belongsTo("workThread", onDelete: .cascade).notNull()
                t.column("content", .text).notNull()
                t.column("isDecision", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_note_thread", on: "note", columns: ["workThreadId", "createdAt"])

            try db.create(table: "threadProposal") { t in
                t.primaryKey("id", .text)
                t.column("repositoryPath", .text).notNull()
                t.column("branch", .text).notNull()
                t.column("suggestedTitle", .text).notNull()
                t.column("suggestedIntent", .text).notNull().defaults(to: "")
                t.column("suggestedNextStep", .text).notNull().defaults(to: "")
                t.column("score", .double).notNull()
                t.column("evidence", .text).notNull()
                t.column("state", .text).notNull().defaults(to: "pending")
                t.column("acceptedThreadId", .text)
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime).notNull()
                t.uniqueKey(["repositoryPath", "branch"])
            }

            try db.create(table: "repoSnapshot") { t in
                t.primaryKey("id", .text)
                t.column("repositoryPath", .text).notNull()
                t.column("branch", .text).notNull()
                t.column("headSha", .text)
                t.column("dirtyFileCount", .integer).notNull().defaults(to: 0)
                t.column("commitsAhead", .integer).notNull().defaults(to: 0)
                t.column("commitsBehind", .integer).notNull().defaults(to: 0)
                t.column("capturedAt", .datetime).notNull()
            }
            try db.create(index: "idx_snapshot_repo", on: "repoSnapshot", columns: ["repositoryPath", "capturedAt"])

            try db.create(table: "scanCache") { t in
                t.primaryKey("filePath", .text)
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("payload", .text).notNull()
                t.column("cachedAt", .datetime).notNull()
            }

            try db.create(table: "ignoredPath") { t in
                t.primaryKey("path", .text)
                t.column("reason", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v1.search") { db in
            // One denormalised index across everything searchable. Kept in sync
            // explicitly by SearchIndex rather than by triggers, so the same code
            // path works for the app and the CLI and is directly testable.
            try db.create(virtualTable: "searchIndex", using: FTS5()) { t in
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("kind").notIndexed()
                t.column("recordId").notIndexed()
                t.column("threadId").notIndexed()
                t.column("title")
                t.column("body")
            }
        }

        // Records each brief shown and whether it beat what the user would have
        // typed. The point of the whole surface is that this number is readable
        // after a week — a product decision, not telemetry: it never leaves here.
        migrator.registerMigration("v2.briefLog") { db in
            try db.create(table: "briefLog") { t in
                t.primaryKey("id", .text)
                t.column("repositoryPath", .text).notNull()
                t.column("repositoryName", .text).notNull()
                t.column("estimatedTokens", .integer).notNull().defaults(to: 0)
                t.column("shownAt", .datetime).notNull()
                t.column("verdict", .text)
                t.column("note", .text)
                t.column("judgedAt", .datetime)
            }
            try db.create(index: "idx_brieflog_shown", on: "briefLog", columns: ["shownAt"])
        }

        // The day timeline. Spans rather than points, so the UI can say
        // "1h 04m" instead of listing the same app forty times.
        migrator.registerMigration("v3.activity") { db in
            try db.create(table: "activityEvent") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("appName", .text).notNull()
                t.column("bundleIdentifier", .text)
                t.column("target", .text)
                t.column("url", .text)
                t.column("note", .text)
                t.column("noteAt", .datetime)
                t.column("metadata", .text).notNull().defaults(to: "{}")
            }
            // The timeline always asks for one day in order; this is the only
            // query shape that matters.
            try db.create(index: "idx_activity_started", on: "activityEvent",
                          columns: ["startedAt"])
        }

        // Lets a session or commit be imported repeatedly without duplicating —
        // the day is rebuilt from transcripts every few minutes.
        migrator.registerMigration("v4.activityExternalId") { db in
            try db.alter(table: "activityEvent") { t in
                t.add(column: "externalId", .text)
            }
            try db.create(
                index: "idx_activity_external", on: "activityEvent",
                columns: ["externalId"], unique: true,
                ifNotExists: true
            )
        }

        // Keyed on the repository, so it outlives the session and the process.
        migrator.registerMigration("v5.projectNote") { db in
            try db.create(table: "projectNote") { t in
                t.primaryKey("repositoryPath", .text)
                t.column("repositoryName", .text).notNull()
                t.column("building", .text).notNull().defaults(to: "")
                t.column("nextStep", .text).notNull().defaults(to: "")
                t.column("isPaused", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
