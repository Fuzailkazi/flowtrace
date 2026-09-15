import Foundation
import GRDB

/// The second choke point.
///
/// The agent adapters redact prompts as they are parsed, which covers
/// everything FlowTrace reads out of a transcript. This covers everything that
/// enters through the `Store` instead: window titles the recorder observed,
/// addresses of pages you had open, and tabs handed over by the browser
/// extension.
///
/// Both are applied *before* any comparison. `describesSameActivity` compares
/// `target` and `url`, so a raw incoming value would never equal the blanked
/// one already stored, and a tokenised page would close and reopen its span on
/// every thirty-second tick.
extension Store {
    /// A URL as it is stored: credential-shaped query and fragment values
    /// blanked, everything else untouched.
    public static func storageURL(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return url }
        return Redaction.redactURL(url)
    }

    /// Free text as it is stored — a window title, a page title. Text that was
    /// *only* a credential becomes nil rather than a row labelled
    /// "[api key removed]".
    ///
    /// This deliberately does not apply to the note you type. Those are your
    /// words, and silently rewriting them would break the one promise the
    /// typography makes. See the phase report for the reasoning.
    public static func storageText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return text }
        let result = Redaction.redact(text)
        if result.redactionCount == 0 { return text }

        // Deliberately not `isOnlyRedactions`, which is tuned for prompts: it
        // treats anything under eight surviving characters as content-free,
        // which is right for "[api key removed]" as a whole prompt and wrong
        // for a window title like "AWS_SECRET_KEY=… — zsh", where "zsh" is the
        // part worth keeping. A title is dropped only when nothing but markers
        // and punctuation is left.
        var stripped = result.text
        for name in Redaction.markerNames {
            stripped = stripped.replacingOccurrences(of: "[\(name) removed]", with: "")
        }
        let remaining = stripped.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return remaining.isEmpty ? nil : result.text
    }

    /// An event with both applied, for the write paths.
    static func forStorage(_ event: ActivityEvent) -> ActivityEvent {
        var event = event
        event.target = storageText(event.target)
        event.url = storageURL(event.url)
        event.metadata = event.metadata.reduce(into: [:]) { out, pair in
            // `place` and `cwd` are paths, `tabsOpen` and `messages` are counts,
            // `about` and `asked` are prompt-derived and already redacted at the
            // adapter — but metadata is an open dictionary, so it is filtered
            // rather than trusted.
            out[pair.key] = storageText(pair.value) ?? ""
        }
        return event
    }
}

// MARK: - Repairing what is already stored

extension Store {
    /// Rewrites everything already in the database through the current rules.
    ///
    /// Run once, from migration `v6.redactStored`. It reads *columns*, never
    /// records: a record-level `fetchAll` throws on one malformed JSON column,
    /// and a throw inside a migration propagates out of `FlowTraceDatabase.init`
    /// — the app would then fail to open its database on every launch, which is
    /// far worse than the single bad row this exists to clean. An undecodable
    /// blob is left exactly as it was.
    public static func redactStoredText(_ db: Database) throws {
        // 1. The scan memo is derived state. Emptying it is cheaper and safer
        //    than rewriting serialised sessions, and the next scan rebuilds it
        //    through the adapters, which now redact.
        try db.execute(sql: "DELETE FROM scanCache")

        // 2. Plain text columns.
        for (table, columns) in [
            ("threadProposal", ["suggestedTitle", "suggestedIntent", "suggestedNextStep"]),
            ("workThread", ["title", "description", "intent", "nextStep"]),
            ("codeContext", ["note", "nextStep"]),
            ("timelineEvent", ["description"]),
            ("activityEvent", ["target"]),
        ] {
            for column in columns {
                try redactColumn(db, table: table, column: column)
            }
        }

        // 3. URL columns.
        for (table, column) in [("activityEvent", "url"), ("browserContext", "url")] {
            let rows = try Row.fetchAll(db, sql: "SELECT id, \(column) FROM \(table)")
            for row in rows {
                guard let value: String = row[column], !value.isEmpty else { continue }
                let cleaned = Redaction.redactURL(value)
                guard cleaned != value else { continue }
                try db.execute(
                    sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                    arguments: [cleaned, row["id"] as String]
                )
            }
        }

        // 4. JSON columns, decoded field by field and re-encoded — never regexed
        //    as text. Two patterns end in `\S` runs that cross quotes and commas,
        //    and JSONEncoder emits no whitespace, so redacting the serialised
        //    form could swallow the start of the next value and leave an
        //    unterminated string.
        try redactEvidence(db, table: "threadProposal", column: "evidence")
        try redactEvidence(db, table: "workThread", column: "detectionEvidence")
        try redactMetadata(db)

        // 5. The search index is a standalone FTS table, so updating the rows
        //    above leaves the old text in its shadow tables. Rebuild it.
        try rebuildSearchIndex(db)
    }

    private static func redactColumn(_ db: Database, table: String, column: String) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, \(column) FROM \(table)")
        for row in rows {
            guard let value: String = row[column], !value.isEmpty else { continue }
            let result = Redaction.redact(value)
            guard result.redactionCount > 0 else { continue }
            try db.execute(
                sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                arguments: [result.text, row["id"] as String]
            )
        }
    }

    private static func redactEvidence(_ db: Database, table: String, column: String) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, \(column) FROM \(table)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        for row in rows {
            guard let raw: String = row[column], !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  var evidence = try? decoder.decode(DetectionEvidence.self, from: data)
            else { continue }

            let before = evidence
            evidence.lastPrompt = evidence.lastPrompt.map { Redaction.redact($0).text }
            evidence.sessionTitle = evidence.sessionTitle.map { Redaction.redact($0).text }
            evidence.lastCommitSubject = evidence.lastCommitSubject.map { Redaction.redact($0).text }
            evidence.promptArc = evidence.promptArc.map { Redaction.redact($0).text }

            guard evidence.lastPrompt != before.lastPrompt
                    || evidence.sessionTitle != before.sessionTitle
                    || evidence.lastCommitSubject != before.lastCommitSubject
                    || evidence.promptArc != before.promptArc,
                  let encoded = try? encoder.encode(evidence)
            else { continue }

            try db.execute(
                sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                arguments: [String(decoding: encoded, as: UTF8.self), row["id"] as String]
            )
        }
    }

    private static func redactMetadata(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, metadata FROM activityEvent")
        for row in rows {
            guard let raw: String = row["metadata"], !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let values = try? JSONDecoder().decode([String: String].self, from: data)
            else { continue }

            var cleaned: [String: String] = [:]
            var changed = false
            for (key, value) in values {
                let result = Redaction.redact(value)
                if result.redactionCount > 0 { changed = true }
                cleaned[key] = result.text
            }
            guard changed, let encoded = try? JSONEncoder().encode(cleaned) else { continue }
            try db.execute(
                sql: "UPDATE activityEvent SET metadata = ? WHERE id = ?",
                arguments: [String(decoding: encoded, as: UTF8.self), row["id"] as String]
            )
        }
    }

    /// Empties the index and writes it again from the repaired rows.
    ///
    /// A thread is reconstructed for indexing with `detectionEvidence: nil`:
    /// the index body never includes evidence, so a row whose evidence will not
    /// decode is still indexed from its plain columns rather than skipped.
    private static func rebuildSearchIndex(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM searchIndex")

        for row in try Row.fetchAll(db, sql: """
            SELECT id, title, description, intent, nextStep, blocker, tags, status
            FROM workThread
            """) {
            var parts = [
                row["description"] as String? ?? "",
                row["intent"] as String? ?? "",
                row["nextStep"] as String? ?? "",
            ]
            if let blocker: String = row["blocker"], !blocker.isEmpty { parts.append("blocked \(blocker)") }
            if let tags: String = row["tags"], let data = tags.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                parts.append(contentsOf: decoded)
            }
            parts.append(row["status"] as String? ?? "")
            let id: String = row["id"]
            try SearchIndex.index(
                db, kind: .thread, recordId: id, threadId: id,
                title: row["title"] as String? ?? "",
                body: parts.filter { !$0.isEmpty }.joined(separator: " \n ")
            )
        }

        for row in try Row.fetchAll(db, sql: """
            SELECT id, workThreadId, pageTitle, url, note, browser FROM browserContext
            WHERE workThreadId IS NOT NULL
            """) {
            try SearchIndex.index(
                db, kind: .tab, recordId: row["id"], threadId: row["workThreadId"],
                title: row["pageTitle"] as String? ?? "",
                body: [
                    row["url"] as String? ?? "", row["note"] as String? ?? "",
                    row["browser"] as String? ?? "",
                ].filter { !$0.isEmpty }.joined(separator: " \n ")
            )
        }

        for row in try Row.fetchAll(db, sql: """
            SELECT id, workThreadId, repositoryName, repositoryPath, branch, note, nextStep, agentName
            FROM codeContext WHERE workThreadId IS NOT NULL
            """) {
            try SearchIndex.index(
                db, kind: .code, recordId: row["id"], threadId: row["workThreadId"],
                title: row["repositoryName"] as String? ?? "",
                body: [
                    row["repositoryPath"] as String? ?? "", row["branch"] as String? ?? "",
                    row["note"] as String? ?? "", row["nextStep"] as String? ?? "",
                    row["agentName"] as String? ?? "",
                ].filter { !$0.isEmpty }.joined(separator: " \n ")
            )
        }

        for row in try Row.fetchAll(db, sql: """
            SELECT id, workThreadId, content, isDecision FROM note
            """) {
            let isDecision: Bool = row["isDecision"] ?? false
            try SearchIndex.index(
                db, kind: .note, recordId: row["id"], threadId: row["workThreadId"],
                title: isDecision ? "Decision" : "Note",
                body: row["content"] as String? ?? ""
            )
        }
    }
}
